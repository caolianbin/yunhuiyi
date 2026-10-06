import 'package:flutter_test/flutter_test.dart';

import 'package:meeting_app/core/app_config.dart';

/// 冒烟测试。
///
/// 放这个文件不只是"有个测试"这么简单：如果 test/ 目录不存在，
/// `flutter create` 会生造一个引用 `MyApp` 的模板测试，而本工程里没有
/// `MyApp` 这个东西 —— 那个文件永远编译不过，会让 CI 上的 `flutter analyze`
/// 直接失败。这里放一个真实可用的测试，既挡住了模板文件，
/// 也顺手守住几条"改了不会报错、但会让功能连不上"的路径约定。
void main() {
  test('REST 前缀与 SignalR Hub 路径要和后端 Program.cs 的映射一致', () {
    // 改错的话现象是：能登录成功，但会议列表永远空 / 实时消息收不到。
    expect(AppConfig.apiPrefix, '/api');
    expect(AppConfig.hubPath, '/hubs/meeting');
  });

  test('默认后端地址必须是完整的 http(s) 地址', () {
    // Session._normalizeBaseUrl 只补协议头，写成裸域名或漏斜杠会拼出
    // 形如 "t.vrtvoi.com/api" 的地址，Dio 直接抛 unsupported scheme。
    expect(AppConfig.defaultBaseUrl, startsWith('http'));
    expect(AppConfig.defaultBaseUrl, isNot(endsWith('/')));
  });

  test('iOS 录屏扩展名不能为空', () {
    // 空值会让系统的录屏选择器里一片空白，且不报任何错。
    expect(AppConfig.iosBroadcastExtension.trim(), isNotEmpty);
  });

  test('屏幕共享编码参数在合理范围（过低看不清、过高会被限流）', () {
    expect(AppConfig.shareFps, inInclusiveRange(5, 30));
    expect(AppConfig.shareBitrateKbps, inInclusiveRange(300, 3000));
  });
}
