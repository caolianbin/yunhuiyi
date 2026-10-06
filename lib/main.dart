import 'package:flutter/material.dart';

import 'app.dart';
import 'core/session.dart';

/// 应用入口。
///
/// ⚠️ 这个**文件名不能改**：`flutter build` / `flutter run` 在不传 `--target`
///    时默认就找 `lib/main.dart`。改名成 `app.dart` 之类，会让所有用默认配置的
///    构建工具直接失败（报 `Target file "lib/main.dart" not found`），
///    Codemagic 的 Flutter 向导模板就是这种情况。
///    所以：入口固定留在 main.dart，`app.dart` 只管 Widget 树。
Future<void> main() async {
  // 必须在 runApp 之前绑定：下面 Session.load() 要读 SharedPreferences，
  // 那是平台通道，没有 binding 会直接抛
  // "Binding has not yet been initialized"。
  WidgetsFlutterBinding.ensureInitialized();

  final session = Session();

  // 先把本地 token / baseUrl 读回来，再决定首屏。
  // ⚠️ 这一行不能省：app.dart 里的 _AuthGate 是看 session.isLoggedIn 分流的，
  //    不 await 的话首帧一定是"未登录"，会先闪一下登录页再跳首页。
  await session.load();

  runApp(MeetingApp(session: session));
}
