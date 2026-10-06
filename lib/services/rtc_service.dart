import 'dart:io';

import 'package:flutter/services.dart';
import 'package:replay_kit_launcher/replay_kit_launcher.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_rtc_sdk/tx_device_manager.dart';

import '../core/app_config.dart';
import '../core/platform_channel.dart';

/// TRTC 只负责「媒体」，会议业务状态（谁在会、谁在共享）由 SignalR 维护。
/// 两者通过 userId 关联：TRTC 的 userId 就是后端的数字 userId
/// （见 RtcController.GetUserSig —— 签名与进房必须使用同一个 userId，
///  否则 TRTC 会以 userSig 校验失败拒绝进房，错误码是 -100018）。
///
/// 本文件用的是官方新包 `tencent_rtc_sdk`（13.x）。
/// 与旧包 `tencent_trtc_cloud` 的差异都收敛在本文件内，其余文件不受影响。

/// 屏幕共享的「启动方式」。
///
/// ⚠️ 两个平台都**不能**在调用后立刻认为共享已经开始：
///   · Android 会弹系统授权框「开始录制或投放？」，用户点「开始」才真正采集；
///   · iOS 会弹系统录屏选择器，用户还要点一下「开始直播」。
///
/// 真正开始的权威信号是 TRTC 的 `onScreenCaptureStarted` 回调
/// （官方示例也是这么处理的：`isSharing` 只在该回调里置位）。
/// 这里返回的枚举只用来决定给用户看哪一句操作指引。
enum ScreenShareTrigger {
  /// Android：等用户在系统 MediaProjection 授权框上点「开始录制」
  mediaProjection,

  /// iOS：等用户在系统录屏选择器上点「开始直播」
  broadcastPicker,
}

abstract class RtcEventListener {
  void onEnterRoom(int result) {}

  void onExitRoom(int reason) {}

  void onRemoteUserEnter(String userId) {}

  void onRemoteUserLeave(String userId) {}

  void onUserVideoAvailable(String userId, bool available) {}

  void onUserAudioAvailable(String userId, bool available) {}

  /// 辅流（屏幕共享）可用性变化 —— 这是"看到别人共享屏幕"的唯一入口
  void onUserSubStreamAvailable(String userId, bool available) {}

  void onFirstVideoFrame(String? userId, TRTCVideoStreamType streamType) {}

  void onScreenCaptureStarted() {}

  void onScreenCaptureStopped(int reason) {}

  /// userId → 音量（0-100），用于说话高亮
  void onVoiceVolume(Map<String, int> volumes) {}

  void onError(int errCode, String errMsg) {}

  void onWarning(int warningCode, String warningMsg) {}
}

class RtcService {
  TRTCCloud? _cloud;
  RtcEventListener? _listener;

  /// ⚠️ 必须持有同一个实例才能在退出时注销 —— 新 SDK 的
  /// unRegisterListener 是按对象引用匹配的，new 一个新对象传进去等于没注销。
  TRTCCloudListener? _nativeListener;

  /// 仅用于控制 Android 的屏幕共享前台服务（iOS 上是空操作）。
  final PlatformChannel _platform = const PlatformChannel();

  bool _entered = false;
  bool _micOn = false;
  bool _cameraOn = false;
  bool _frontCamera = true;
  bool _sharing = false;

  /// 本地用户 id。TRTC 的音量回调里，本地用户的 userId 是空字符串，
  /// 需要用它补回来，"自己说话时高亮自己"才有效。
  String _selfUserId = '';

  /// 记住本地预览用的 viewId：关掉再打开摄像头时需要重新 startLocalPreview
  int? _localViewId;

  TRTCCloud? get cloud => _cloud;
  bool get isEntered => _entered;
  bool get isMicOn => _micOn;
  bool get isCameraOn => _cameraOn;
  bool get isFrontCamera => _frontCamera;
  bool get isSharing => _sharing;
  bool get isScreenShareSupported => Platform.isAndroid || Platform.isIOS;

  /// 必须在进房前调用：拿到单例并注册事件监听。
  Future<void> init(RtcEventListener listener) async {
    _listener = listener;
    _cloud ??= await TRTCCloud.sharedInstance();
    _nativeListener = _buildListener();
    _cloud!.registerListener(_nativeListener!);
    // 每 300ms 上报一次音量，用于把正在说话的人框出来。
    // 新 SDK 需要显式传参对象，interval <= 0 会关闭回调。
    _cloud!.enableAudioVolumeEvaluation(
      true,
      TRTCAudioVolumeEvaluateParams(interval: 300),
    );
  }

  /// 构造事件监听对象。
  ///
  /// 新 SDK 是**强类型命名回调**（对比旧包的「枚举 + dynamic params」），
  /// 用错参数编译器直接报错，不再需要在运行时猜 Map 的 key。
  TRTCCloudListener _buildListener() {
    return TRTCCloudListener(
      onError: (errCode, errMsg) {
        _listener?.onError(errCode, errMsg);
      },
      onWarning: (warningCode, warningMsg) {
        _listener?.onWarning(warningCode, warningMsg);
      },
      onEnterRoom: (result) {
        // result > 0 表示进房耗时(ms)，< 0 表示错误码
        _entered = result > 0;
        _listener?.onEnterRoom(result);
      },
      onExitRoom: (reason) {
        _entered = false;
        _sharing = false;
        _listener?.onExitRoom(reason);
      },
      onRemoteUserEnterRoom: (userId) {
        _listener?.onRemoteUserEnter(userId);
      },
      onRemoteUserLeaveRoom: (userId, reason) {
        _listener?.onRemoteUserLeave(userId);
      },
      onUserVideoAvailable: (userId, available) {
        _listener?.onUserVideoAvailable(userId, available);
      },
      onUserSubStreamAvailable: (userId, available) {
        _listener?.onUserSubStreamAvailable(userId, available);
      },
      onUserAudioAvailable: (userId, available) {
        _listener?.onUserAudioAvailable(userId, available);
      },
      onFirstVideoFrame: (userId, streamType, width, height) {
        _listener?.onFirstVideoFrame(userId, streamType);
      },
      onScreenCaptureStarted: () {
        _sharing = true;
        _listener?.onScreenCaptureStarted();
      },
      onScreenCaptureStopped: (reason) {
        _sharing = false;
        _listener?.onScreenCaptureStopped(reason);
      },
      onUserVoiceVolume: (userVolumes, totalVolume) {
        final map = <String, int>{};
        for (final v in userVolumes) {
          // 本地用户的 userId 是空串，用进房时记下的 id 补上
          final uid = v.userId.isEmpty ? _selfUserId : v.userId;
          if (uid.isEmpty) continue;
          map[uid] = v.volume;
        }
        _listener?.onVoiceVolume(map);
      },
    );
  }

  // ==================== 房间 ====================

  Future<void> enterRoom({
    required int sdkAppId,
    required String userId,
    required String userSig,
    required int roomId,
  }) async {
    final cloud = _cloud;
    if (cloud == null) throw StateError('TRTC 未初始化');
    _selfUserId = userId;
    cloud.enterRoom(
      TRTCParams(
        sdkAppId: sdkAppId,
        userId: userId,
        userSig: userSig,
        // 后端以「会议 ID」作为房间号（roomIdType = number），两端必须一致
        roomId: roomId,
        role: TRTCRoleType.anchor,
      ),
      TRTCAppScene.videoCall,
    );
  }

  Future<void> exitRoom() async {
    if (!_entered) return;
    _entered = false;
    _sharing = false;
    _cloud?.exitRoom();
  }

  // ==================== 本地视频 ====================

  /// [viewId] 来自 TRTCCloudVideoView 的 onViewCreated 回调
  Future<void> startLocalPreview(int viewId) async {
    _localViewId = viewId;
    _cameraOn = true;
    final cloud = _cloud;
    if (cloud == null) return;
    cloud.startLocalPreview(_frontCamera, viewId);
    // 摄像头清晰度：640x360 横向，兼顾清晰度与流量
    cloud.setVideoEncoderParam(TRTCVideoEncParam(
      videoFps: 15,
      videoBitrate: 550,
      minVideoBitrate: 200,
      videoResolution: TRTCVideoResolution.res_640_360,
      videoResolutionMode: TRTCVideoResolutionMode.landscape,
    ));
  }

  Future<void> stopLocalPreview() async {
    _cameraOn = false;
    _cloud?.stopLocalPreview();
  }

  /// 开关摄像头。
  ///
  /// 关闭时同时 muteLocalVideo，确保远端真的收到 available=false，
  /// 而不是继续显示最后一帧（否则别人会看到你"卡住的画面"）。
  Future<void> setCameraEnabled(bool on) async {
    final cloud = _cloud;
    if (cloud == null) return;
    if (on) {
      cloud.muteLocalVideo(TRTCVideoStreamType.big, false);
      final vid = _localViewId;
      if (vid != null) {
        _cameraOn = true;
        cloud.startLocalPreview(_frontCamera, vid);
      }
    } else {
      cloud.muteLocalVideo(TRTCVideoStreamType.big, true);
      cloud.stopLocalPreview();
      _cameraOn = false;
    }
  }

  Future<void> switchCamera() async {
    final next = !_frontCamera;
    try {
      // 新 SDK 返回 int：0 表示成功，非 0 不切换状态，
      // 避免"状态显示已翻转但摄像头其实没换"的错位。
      final ret = _cloud?.getDeviceManager().switchCamera(next);
      if (ret == 0) _frontCamera = next;
    } catch (_) {
      // 切换失败保持原状态
    }
  }

  // ==================== 远端视频 ====================

  /// 订阅远端画面。
  ///
  /// [streamType] 主路(big)=摄像头，辅路(sub)=屏幕共享。
  /// 必须在 TRTCCloudVideoView 的 onViewCreated 之后调用，viewId 才有意义。
  Future<void> startRemoteView(
    String userId,
    TRTCVideoStreamType streamType,
    int viewId,
  ) async {
    if (userId.isEmpty) return;
    final cloud = _cloud;
    if (cloud == null) return;
    cloud.startRemoteView(userId, streamType, viewId);
    // 摄像头用铺满，屏幕共享用完整显示（否则共享的文档会被裁掉边缘）
    cloud.setRemoteRenderParams(
      userId,
      streamType,
      TRTCRenderParams(
        fillMode: streamType == TRTCVideoStreamType.sub
            ? TRTCVideoFillMode.fit
            : TRTCVideoFillMode.fill,
      ),
    );
  }

  Future<void> stopRemoteView(
    String userId,
    TRTCVideoStreamType streamType,
  ) async {
    if (userId.isEmpty) return;
    _cloud?.stopRemoteView(userId, streamType);
  }

  // ==================== 音频 ====================

  Future<void> startLocalAudio() async {
    _micOn = true;
    final cloud = _cloud;
    if (cloud == null) return;
    cloud.startLocalAudio(TRTCAudioQuality.defaultMode);
    // 视频会议场景必须显式设为扬声器：
    // 默认走听筒，音量极小，用户会以为"对方没声音"。
    _setRoute(TXAudioRoute.speakerPhone);
  }

  Future<void> stopLocalAudio() async {
    _micOn = false;
    _cloud?.stopLocalAudio();
  }

  Future<void> muteLocalAudio(bool mute) async {
    _micOn = !mute;
    _cloud?.muteLocalAudio(mute);
  }

  Future<void> setSpeakerOn(bool speaker) async {
    _setRoute(speaker ? TXAudioRoute.speakerPhone : TXAudioRoute.earpiece);
  }

  void _setRoute(TXAudioRoute route) {
    try {
      _cloud?.getDeviceManager().setAudioRoute(route);
    } catch (_) {
      // 部分设备（无听筒的平板）切路由可能失败，忽略即可
    }
  }

  Future<void> setRemoteVolume(String userId, int volume) async {
    _cloud?.setRemoteAudioVolume(userId, volume);
  }

  /// 全部静音（仅本端播放静音，不影响远端采集）
  Future<void> muteAllRemoteAudio(bool mute) async {
    _cloud?.muteAllRemoteAudio(mute);
  }

  // ==================== 屏幕共享 ====================

  /// 开始屏幕共享（走辅流 sub，与摄像头主路互不干扰）。
  ///
  /// 返回「需要用户去点什么」，**不代表共享已开始** —— 见 [ScreenShareTrigger]。
  ///
  /// - Android：系统级录屏，会弹「开始录制」授权框，需要前台服务配合（先起服务再采集）。
  /// - iOS：必须走 [TRTCCloud.startScreenCaptureByReplaykit]，
  ///   由 Broadcast Upload Extension 采集整块系统屏幕；appGroup 是主 App 与扩展进程
  ///   之间传画面的唯一通道。
  ///
  /// 失败会抛 [StateError]，由调用方转成用户可读的提示。
  Future<ScreenShareTrigger> startScreenCapture() async {
    final cloud = _cloud;
    if (cloud == null) throw StateError('TRTC 未初始化');

    final enc = TRTCVideoEncParam(
      videoFps: AppConfig.shareFps,
      videoBitrate: AppConfig.shareBitrateKbps,
      minVideoBitrate: 200,
      videoResolution: TRTCVideoResolution.res_1280_720,
      videoResolutionMode: TRTCVideoResolutionMode.landscape,
    );

    if (Platform.isIOS) {
      final appGroup = AppConfig.iosAppGroup.trim();
      // ⚠️ 这里**不能**把空值放过去。
      //    插件 iOS 端是用 `getParamByKey(...) as? String` 取参的，Dart 侧的 null
      //    会被桥接层转成空串（见 trtc_method_channel.dart 里的 `appGroup ?? ""`），
      //    空串能通过类型检查、也真的会调进原生 SDK，但扩展进程与主进程没挂在
      //    同一个共享容器上，扩展采到的帧主进程一个都收不到 ——
      //    表现是「共享按钮亮了、屏幕顶部也变红，会议里谁都没看到画面」，
      //    全程没有任何报错，属于最难查的一类。
      //    所以宁可在这里显式失败，也不要把它留到运行时。
      if (appGroup.isEmpty) {
        throw StateError(
          'iOS App Group 未配置，屏幕共享无法把画面从录屏扩展传给主进程。'
          '请检查 AppConfig.iosAppGroup，并重跑 python platform/apply.py。',
        );
      }
      cloud.startScreenCaptureByReplaykit(
        TRTCVideoStreamType.sub,
        enc,
        appGroup,
      );

      // ⚠️ 关键一步，缺了整个 iOS 屏幕共享就是"点了没反应"：
      //    从 iOS 11 起系统不允许 App 自己启动系统级录屏。
      //    startScreenCaptureByReplaykit 只是让 SDK 进入"等待共享数据"的状态，
      //    它**不弹任何界面**。必须弹出系统的 RPSystemBroadcastPickerView
      //    让用户点一下「开始直播」，共享才会真的开始。
      try {
        await _launchIosBroadcastPicker();
      } catch (_) {
        // 触发入口没出来 → 把刚才那次"进入等待"收回去，
        // 不要让 SDK 停在一个半开状态（虽然它不会推流，但状态机要干净）。
        cloud.stopScreenCapture();
        rethrow;
      }
      return ScreenShareTrigger.broadcastPicker;
    }

    if (Platform.isAndroid) {
      // ⚠️ 顺序很关键：安卓要先起前台服务，再调 startScreenCapture。
      //    反过来会在系统授权回调那一刻直接崩：
      //    java.lang.SecurityException: Media projections require a foreground
      //    service of type ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
      //    at com.tencent.rtmp.video.TXScreenCapture$TXScreenCaptureAssistantActivity.onActivityResult
      await _platform.startScreenShareService();
    }
    // Android：系统弹「开始录制或投放？」授权框，用户同意后才真正开始采集。
    // viewId 传 null —— 共享画面不需要本地预览渲染。
    cloud.startScreenCapture(null, TRTCVideoStreamType.sub, enc);
    return ScreenShareTrigger.mediaProjection;
  }

  /// 弹出 iOS 系统录屏选择器。
  ///
  /// 单独抽出来是为了把「插件没链接」这种构建期问题和「用户没配扩展」这种
  /// 配置期问题区分开 —— 两者的排查方向完全不同。
  Future<void> _launchIosBroadcastPicker() async {
    final bool launched;
    try {
      launched = await ReplayKitLauncher.launch(AppConfig.iosBroadcastExtension);
    } on MissingPluginException {
      throw StateError(
        'iOS 录屏触发插件未链接（可能没执行 pod install 就构建了）。'
        '请在 ios/ 目录下执行 pod install 后重新构建。',
      );
    } catch (e) {
      throw StateError('无法弹出系统录屏选择器：$e');
    }
    if (!launched) {
      throw StateError(
        '没能弹出系统录屏选择器。请确认已在 Xcode 里创建 Broadcast Upload '
        'Extension，且 Product Name 与 AppConfig.iosBroadcastExtension'
        '（当前为 "${AppConfig.iosBroadcastExtension}"）一致。'
        '详见 platform/README.md 的 iOS 章节。',
      );
    }
  }

  Future<void> stopScreenCapture() async {
    _sharing = false;
    _cloud?.stopScreenCapture();
    // 关掉前台服务，清掉通知栏残留的「正在共享屏幕」。
    await _platform.stopScreenShareService();
  }

  Future<void> pauseScreenCapture() async => _cloud?.pauseScreenCapture();

  Future<void> resumeScreenCapture() async => _cloud?.resumeScreenCapture();

  Future<void> dispose() async {
    try {
      final l = _nativeListener;
      if (l != null) _cloud?.unRegisterListener(l);
      _cloud?.exitRoom();
    } catch (_) {
      // 忽略退出异常
    }
    _nativeListener = null;
    _entered = false;
    _sharing = false;
    _listener = null;
  }
}

/// TRTC 错误码 → 用户能看懂的话。
///
/// ⚠️ 这里的码值**逐条对着官方错误码表核过**（trtc.io/zh/document/35142 等）。
///    不要凭印象改：错误码写错会把排查方向彻底带偏，而且很难发现 ——
///    例如 `-3317` 其实是 **sdkAppId 错误**，签名校验失败是 `-100018`；
///    摄像头/麦克风没权限也不是 `-10000x` 而是 `-1314` / `-1317`。
///
/// [errMsg] 是 SDK 自带的可读描述。没有收录的码就把原文附上 ——
/// 只抛一个数字给用户（或给自己）看，等于没提示。
String describeTrtcError(int code, {String errMsg = ''}) {
  final known = _knownTrtcError(code);
  if (known != null) return known;
  final detail = errMsg.trim();
  if (detail.isEmpty) return '音视频错误（code: $code）';
  return '音视频错误（code: $code）：$detail';
}

String? _knownTrtcError(int code) {
  switch (code) {
    // ──────── 屏幕共享（与本项目的核心能力直接相关）────────
    case -1308:
      return '开始录屏失败：一般是录屏权限被拒绝。'
          '安卓请在系统弹窗上点「开始录制」；'
          'iOS 请在弹出的录屏选择器里点「开始直播」。'
          '若之前拒绝过，需到系统设置里重新允许。';
    case -1309:
      return '当前系统不支持屏幕共享（安卓需 5.0 以上，iOS 需 11.0 以上）。';
    case -7001:
      return '录屏被系统中止（可能是用户手动停止，或系统回收了录屏进程）。';
    case -102015:
      return '没有上行辅流的权限。';
    case -102016:
      return '房间里已经有人在共享屏幕了 —— TRTC 同一时刻只允许一个人上行辅流。'
          '请等对方停止共享后再试。';

    // ──────── 摄像头 / 麦克风（设备类）────────
    case -1301:
      return '打开摄像头失败。';
    case -1302:
      return '打开麦克风失败。';
    case -1314:
      return '摄像头未授权：请在系统权限里允许本 App 使用摄像头。';
    case -1316:
      return '摄像头正被其他应用占用，请关掉相机/直播类 App 后重试。';
    case -1317:
      return '麦克风未授权：请在系统权限里允许本 App 使用麦克风。';
    case -1319:
      return '麦克风正被占用（例如正在通话中），请结束后重试。';

    // ──────── 进房 ────────
    case -3301:
      return '进入房间失败，具体原因见后面的 SDK 描述。';
    case -3308:
      return '进房超时：请检查网络，或关掉 VPN / 换 4G 再试。';
    case -3317:
      return '进房参数 sdkAppId 错误 —— 注意这**不是**签名问题。'
          '请核对后端返回的 TRTC AppId 与腾讯云控制台是否一致。';
    case -3318:
      return '进房参数 roomId 错误（roomId 与 strRoomId 不能混用）。';
    case -3319:
      return '进房参数 userId 不正确（后端签发的 userId 与进房用的不是同一个）。';
    case -3320:
      return '进房参数 userSig 不正确（可能为空）。';
    case -3340:
      return '进房请求被拒绝：检查是否用同一个房间号连续调用了进房。';
    case -100018:
      return 'userSig 校验失败：签名与 userId 不匹配或已过期。'
          '请确认后端 /api/rtc/usersig 用的是**数字 userId**（不是昵称）签发，'
          '客户端进房用的也是同一个 userId。';

    // ──────── 网络 ────────
    case -100013:
      return '网络连接失败，请检查网络后重试。';

    default:
      return null;
  }
}
