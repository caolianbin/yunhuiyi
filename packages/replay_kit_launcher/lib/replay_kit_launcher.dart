import 'package:flutter/services.dart';

/// iOS 系统级屏幕共享的「触发按钮」。
///
/// ──────────── 为什么需要这个东西 ────────────
/// 从 iOS 11 起，系统就不允许 App 自己启动系统级录屏了（只能录本 App 画面的
/// in-app 录制不受此限）。必须由**用户主动触发**。
///
/// 而 TRTC 的 `startScreenCaptureByReplaykit(...)` 只是让 SDK 进入
/// **"等待共享数据"** 的状态，它本身**不弹任何界面**。
///
/// 两者叠加的结果就是：如果不给用户一个触发入口，用户点了「共享屏幕」之后
/// 界面上**什么都不会发生** —— 看起来就像功能坏了，
/// 但日志里没有任何错误。这是 iOS 屏幕共享最容易被误判的一环。
///
/// 本插件做的就是弹出系统的 `RPSystemBroadcastPickerView`，
/// 用户点一下即可选择「会议屏幕共享」开始直播。
class ReplayKitLauncher {
  static const MethodChannel _channel = MethodChannel('replay_kit_launcher');

  /// 弹出系统录屏选择器。
  ///
  /// [extensionName] 是 Broadcast Upload Extension 的 **Product Name**，
  /// 也就是扩展产物 `xxx.appex` 的文件名（本项目里固定是 `BroadcastExtension`）。
  ///
  /// ⚠️ 这个名字传错，系统弹窗里会**一片空白** —— 列不出任何可选扩展，
  /// 用户完全不知道怎么办。它和 Xcode 里 target 的 Product Name 必须一致。
  static Future<bool> launch(String extensionName) async {
    final ok = await _channel.invokeMethod<bool>(
      'launchReplayKitBroadcast',
      {'extensionName': extensionName},
    );
    return ok ?? false;
  }
}
