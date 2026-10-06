import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// 一次「进会议所需权限」申请的结果。
class MediaPermissionResult {
  const MediaPermissionResult({
    required this.camera,
    required this.microphone,
    required this.permanentlyDenied,
  });

  final bool camera;
  final bool microphone;

  /// 任一权限被勾了「不再询问」—— 再调 request 也不会弹框，只能去系统设置里开。
  final bool permanentlyDenied;

  bool get allGranted => camera && microphone;

  /// 给用户看的提示；权限齐了返回 null。
  String? get message {
    if (allGranted) return null;
    final missing = <String>[
      if (!camera) '摄像头',
      if (!microphone) '麦克风',
    ].join('、');
    if (permanentlyDenied) {
      return '缺少「$missing」权限，系统已不再弹窗。'
          '请到系统的应用权限设置里手动开启，否则对方看不到你的画面、听不到你的声音。';
    }
    return '你拒绝了「$missing」权限，对方将看不到你的画面、听不到你的声音。'
        '可在系统设置中重新开启。';
  }
}

/// 运行时权限。
///
/// ──────────── 为什么必须主动申请 ────────────
/// Android 6（API 23）起，CAMERA / RECORD_AUDIO 属于**危险权限**，
/// 只在 Manifest 里声明是不够的，必须运行时申请。
/// 不申请的话 TRTC 会静默失败，报的是这两个错误码：
///
///   -1314  ERR_CAMERA_NOT_AUTHORIZED  摄像头未授权
///   -1317  ERR_MIC_NOT_AUTHORIZED     麦克风未授权
///
/// 现象是「能进会议、能看到别人、但自己黑屏且没声音」，
/// 而且**不弹任何系统框**，很难往权限方向想。
///
/// （注：这两个码值对着官方错误码表核过。旧注释里写的 -100006 / -100007
///   在官方表里并不对应摄像头/麦克风权限，属于误记，已更正。）
///
/// iOS 侧由 TRTC 原生层自己触发系统弹窗（前提是 Info.plist 有对应的
/// NS*UsageDescription，见 platform/apply.py），主动申请则是双保险。
class AppPermissions {
  const AppPermissions._();

  static bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 进会议前调用：申请摄像头 + 麦克风。
  static Future<MediaPermissionResult> requestForMeeting() async {
    if (!_mobile) {
      return const MediaPermissionResult(
        camera: true,
        microphone: true,
        permanentlyDenied: false,
      );
    }
    try {
      final statuses =
          await [Permission.camera, Permission.microphone].request();
      final cam = statuses[Permission.camera] ?? PermissionStatus.denied;
      final mic = statuses[Permission.microphone] ?? PermissionStatus.denied;
      return MediaPermissionResult(
        camera: cam.isGranted || cam.isLimited,
        microphone: mic.isGranted || mic.isLimited,
        permanentlyDenied: cam.isPermanentlyDenied || mic.isPermanentlyDenied,
      );
    } catch (e) {
      debugPrint('[AppPermissions] 申请音视频权限失败: $e');
      // 申请动作本身失败时不拦着用户：让 TRTC 去暴露真正的问题，
      // 至少还能进会议看到/听到别人。
      return const MediaPermissionResult(
        camera: true,
        microphone: true,
        permanentlyDenied: false,
      );
    }
  }

  /// Android 13+ 的通知权限。
  ///
  /// 不影响屏幕共享功能本身，但没这个权限时**前台服务的通知不显示**，
  /// 用户会以为"根本没在共享"。所以开始共享前顺手申请一下。
  static Future<void> requestNotificationIfNeeded() async {
    if (!_mobile) return;
    try {
      if (Platform.isAndroid) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[AppPermissions] 申请通知权限失败: $e');
    }
  }

  /// 跳到系统设置页（用户永久拒绝权限后引导过去）。
  static Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      debugPrint('[AppPermissions] 打开系统设置失败: $e');
    }
  }
}
