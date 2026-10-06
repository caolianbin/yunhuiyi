import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与原生（Android）通信的小通道。
///
/// 目前只用来控制 **屏幕共享前台服务** —— 这是 Android 上屏幕共享能否跑起来的
/// 硬性前提，不先起服务直接调 TRTC 的 startScreenCapture 会在系统授权回调时
/// 抛 SecurityException（详见 platform/android/ScreenShareService.kt 顶部注释）。
///
/// iOS 不需要这一步：iOS 的系统级共享由 ReplayKit 扩展进程完成，
/// 所以下面的方法在 iOS / 桌面端上是空操作，调了也不会出错。
class PlatformChannel {
  const PlatformChannel();

  /// 必须与 android/app/src/main/kotlin/**/MainActivity.kt 里的 channelName 一致。
  static const String _channelName = 'meeting_app/platform';

  static const MethodChannel _channel = MethodChannel(_channelName);

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// 开始屏幕共享【前】调用。
  Future<void> startScreenShareService() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('startScreenShareService');
    } on PlatformException catch (e) {
      // 起服务失败不阻断流程：交给随后的 startScreenCapture 去暴露真正的问题，
      // 这里吞掉异常并留日志，避免一次失败把整个共享按钮卡死。
      debugPrint('[PlatformChannel] startScreenShareService 失败: ${e.message}');
    } on MissingPluginException {
      debugPrint('[PlatformChannel] 原生通道未注册，请确认已替换 MainActivity.kt');
    }
  }

  /// 停止屏幕共享【后】调用，清掉通知栏残留的「正在共享屏幕」。
  Future<void> stopScreenShareService() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopScreenShareService');
    } on PlatformException catch (e) {
      debugPrint('[PlatformChannel] stopScreenShareService 失败: ${e.message}');
    } on MissingPluginException {
      // 忽略
    }
  }

  /// 用户拒绝了相机/麦克风/通知权限时，跳到系统设置页让它手动开。
  Future<void> openAppSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openAppSettings');
    } catch (_) {
      // 打不开就算了，不影响主流程
    }
  }
}
