import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/app_theme.dart';
import 'core/session.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'services/auth_service.dart';
import 'services/meeting_service.dart';

/// 依赖注入 + 登录态分流。
///
/// 用 Provider 而不是全局单例，是为了让"退出登录 → 清理连接"这类生命周期
/// 能被 Widget 树自然管理，避免 RoomController 泄漏 TRTC 实例。
class MeetingApp extends StatelessWidget {
  const MeetingApp({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final api = ApiClient(session);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Session>.value(value: session),
        Provider<ApiClient>.value(value: api),
        Provider<AuthService>(create: (_) => AuthService(api)),
        Provider<MeetingService>(create: (_) => MeetingService(api)),
      ],
      child: MaterialApp(
        title: '会议系统',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const _AuthGate(),
      ),
    );
  }
}

/// 根据本地 token 决定进登录页还是首页。
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.watch<Session>().isLoggedIn;
    return loggedIn ? const HomePage() : const LoginPage();
  }
}
