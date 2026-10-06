/// 全局配置。
///
/// ⚠️ 后端地址是打包时最容易被忽略的一项：
///   - Android 模拟器访问宿主机 → http://10.0.2.2:5000
///   - 真机 / iOS 模拟器      → http://<开发机局域网IP>:5000（手机与电脑需同一 WiFi）
///   - 127.0.0.1 在手机上指向手机自己，一定连不上
///
/// 为避免"改地址就要重新打包"，本应用支持在登录页的「服务器设置」里运行时修改，
/// 修改结果持久化在本地，优先于这里的默认值。
class AppConfig {
  const AppConfig._();

  /// 默认后端地址（可被登录页的「服务器设置」覆盖）
  static const String defaultBaseUrl = 'http://192.168.1.100:5000';

  /// SignalR Hub 路径（与后端 Program.cs 中 MapHub<MeetingHub>("/hubs/meeting") 对应）
  static const String hubPath = '/hubs/meeting';

  /// REST 前缀
  static const String apiPrefix = '/api';

  /// iOS 屏幕共享所需的 App Group。
  ///
  /// ⚠️ 这个字符串必须与下面 4 处**一字不差**（大小写也算）。
  ///    大小写不一致是本项目最难查的一类问题：控制中心里录屏图标正常显示、
  ///    手机顶部也变红，但会议里所有人都看不到你的屏幕 —— 因为两个沙盒
  ///    没挂到同一个共享容器上，扩展采到的帧主进程收不到。
  ///
  ///   1. ios/Runner/Runner.entitlements            → com.apple.security.application-groups
  ///   2. ios/BroadcastExtension/BroadcastExtension.entitlements（同上）
  ///   3. ios/BroadcastExtension/SampleHandler.swift → APPGROUP 常量
  ///   4. Apple 开发者后台：主 App 与扩展的 App ID 都要勾上这个 App Group
  ///
  /// 改包名 / 换开发者账号时，直接重跑：
  ///     python platform/apply.py --no-create --org com.acme
  /// 脚本会把 entitlements、扩展的 SampleHandler.swift 与**本常量**一并写成
  /// `group.com.acme.meetingApp`，不需要手工改任何一处。
  ///
  /// Android 不使用该值（系统级录屏走 MediaProjection + 前台服务，不需要 App Group）。
  static const String iosAppGroup = 'group.com.example.meetingApp';

  /// iOS 录屏扩展的 Product Name（即 `BroadcastExtension.appex` 里的
  /// `BroadcastExtension`），供弹出系统录屏选择器时指定要启动哪个扩展。
  ///
  /// ⚠️ 必须与 Xcode 里 Broadcast Upload Extension target 的 **Product Name**
  ///    完全一致。传错的话系统那个选择器里会**一片空白**（列不出任何可选扩展），
  ///    用户完全不知道该怎么办，而且不会有任何报错。
  static const String iosBroadcastExtension = 'BroadcastExtension';

  /// 屏幕共享编码参数
  static const int shareFps = 10;
  static const int shareBitrateKbps = 1200;

  /// 网络超时
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);
}
