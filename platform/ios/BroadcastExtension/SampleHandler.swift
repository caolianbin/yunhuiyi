//
//  SampleHandler.swift
//  BroadcastUploadExtension（录屏扩展）
//
//  ⚠️ 这个文件必须放在 **Broadcast Upload Extension 这个独立 Target** 里，
//     不是主 App 的 Runner Target。iOS 的系统级屏幕共享（别的 App 也能被录到）
//     必须由系统进程调用这个扩展来采集屏幕，主 App 自己采集不到。
//
//  这是本项目从 uni-app / HBuilderX 换成 Flutter 的**唯一原因**：
//  HBuilderX 云打包无法往 iOS 工程里插入这个 Extension Target，
//  而 Flutter 工程可以直接用 Xcode 打开、手动加 Target。
//
//  对接关系（三处必须完全一致，否则扩展和主 App 跨进程通信会失败）：
//    1. 本文件常量 APPGROUP
//    2. 主 App 的 Runner.entitlements            → com.apple.security.application-groups
//    3. 本扩展的 BroadcastExtension.entitlements → com.apple.security.application-groups
//    4. Dart 侧 app/lib/core/app_config.dart      → AppConfig.iosAppGroup
//  同时还要在 Apple Developer 后台把两个 App ID 都勾上同一个 App Group。
//

import ReplayKit
// 由 Podfile 里的 pod 'TXLiteAVSDK_Professional/ReplayKitExt' 提供
import TXLiteAVSDK_ReplayKitExt

/// 必须与主 App 的 App Group、以及 Dart 侧 AppConfig.iosAppGroup 保持一致。
let APPGROUP = "group.com.example.meetingApp"

class SampleHandler: RPBroadcastSampleHandler, TXReplayKitExtDelegate {

    let recordScreenKey = Notification.Name.init("TRTCRecordScreenKey")

    // MARK: - 系统录屏回调

    /// 用户在「屏幕录制」里点了「开始共享」后，系统创建本扩展并调用这里。
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 用 App Group 把本扩展挂到 TRTC 主进程的屏幕上，之后 sendVideoSampleBuffer
        // 送出的帧就会被主进程推成「辅流」。
        TXReplayKitExt.sharedInstance().setup(withAppGroup: APPGROUP, delegate: self)
    }

    override func broadcastPaused() {
        // 用户暂停录屏；被暂停期间系统不再回调 processSampleBuffer，无需处理。
    }

    override func broadcastResumed() {
        // 用户恢复录屏。
    }

    override func broadcastFinished() {
        TXReplayKitExt.sharedInstance().broadcastFinished()
    }

    // MARK: - 每一帧都会走到这里

    /// 系统采集到的每一帧（视频 / App 音频 / 麦克风音频）都会送到这个方法。
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            // 只把画面送进 TRTC 变成辅流。
            // 页面里「看到别人共享的屏幕」靠的就是主进程收到辅流后
            // 触发 onUserSubStreamAvailable，再 startRemoteView(streamType=SUB)。
            TXReplayKitExt.sharedInstance().sendVideoSampleBuffer(sampleBuffer)

        case RPSampleBufferType.audioApp:
            // 官方示例此处不转发：共享时的声音由麦克风（主路音频）采集，
            // 不额外把系统播放的声音混进去，避免和麦克风产生回音/重音。
            break

        case RPSampleBufferType.audioMic:
            // 同上，麦克风音频已经由主 App 的 TRTC 采集，这里不重复发送。
            break

        @unknown default:
            break
        }
    }

    // MARK: - TXReplayKitExtDelegate

    /// 结束录屏时回调，用来把「为什么结束」告诉系统，控制中心的状态提示才准确。
    func broadcastFinished(_ broadcast: TXReplayKitExt, reason: TXReplayKitExtReason) {
        var tip = ""
        switch reason {
        case TXReplayKitExtReason.requestedByMain:
            // 主 App 主动调了 stopScreenCapture
            tip = "屏幕共享已结束"
        case TXReplayKitExtReason.disconnected:
            tip = "应用断开"
        case TXReplayKitExtReason.versionMismatch:
            // 主 App 的 TXLiteAVSDK_Professional 与本扩展的 ReplayKitExt
            // 版本号不一致时会出现，务必让两者版本保持一致（见 Podfile）
            tip = "集成错误（SDK 版本号不相符合）"
        default:
            break
        }

        let error = NSError(
            domain: NSStringFromClass(self.classForCoder),
            code: 0,
            userInfo: [NSLocalizedFailureReasonErrorKey: tip]
        )
        finishBroadcastWithError(error)
    }
}
