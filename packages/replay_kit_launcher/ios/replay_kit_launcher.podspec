#
# 本地 fork 的 podspec（不发布到 pub.dev）。
#
# 之所以不直接用 pub.dev 上的同名包：
#   1. 那个包发布于 2022 年，pubspec 的 SDK 约束是 `>=2.12.0 <3.0.0`，
#      而本工程是 Dart 3.12，直接依赖会版本求解失败；
#   2. 它的实现只走「遍历子视图模拟点击」这一条路，没有兜底。
#
Pod::Spec.new do |s|
  s.name             = 'replay_kit_launcher'
  s.version          = '1.0.1'
  s.summary          = 'Launch iOS system-wide screen sharing by presenting RPSystemBroadcastPickerView'
  s.description      = <<-DESC
TRTC's startScreenCaptureByReplaykit only puts the SDK into a waiting state;
it does not present any UI. This plugin provides the missing trigger button.
                       DESC
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'meeting_app' => 'dev@example.com' }
  s.source           = { :path => '.' }

  s.source_files        = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  # RPSystemBroadcastPickerView 需要 iOS 12+。
  # 这里写 12.0 而不是跟着主工程写 13.0，是为了让插件本身保持可复用；
  # 实际构建时 CocoaPods 会取工程 Podfile 里更高的 13.0。
  s.platform   = :ios, '12.0'
  s.frameworks = 'ReplayKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
