#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
一键给 Flutter 工程打好 Android / iOS 平台配置补丁。

为什么需要这个脚本：
    `flutter create` 生成的工程只带最小配置，缺少会议 App 必须的东西：
      · Android：相机/麦克风/通知权限、录屏前台服务、明文 HTTP、minSdk、混淆规则
      · iOS    ：相机/麦克风隐私描述、App Group、ReplayKit 扩展、Podfile 扩展 target
    手工改容易漏，且这些坑都是「不报错但功能不工作」的类型，所以做成脚本。

用法（在 app/ 目录下）：
    python platform/apply.py                  # 完整流程（含 flutter create）
    python platform/apply.py --no-create      # 已经跑过 flutter create，只打补丁
    python platform/apply.py --org com.acme --app-group group.com.acme.meeting

脚本是**幂等**的：重复执行不会产生重复权限声明或重复 service。
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.dirname(HERE)

DEFAULT_ORG = 'com.example'
# App Group 默认由 --org 推导（group.<org>.meetingApp），与 Bundle ID com.<org>.meetingApp 对齐。
# 注意：Apple 后台里 App Group 用的是 Team ID 前缀而不是 org，但对本项目来说
# 只要「entitlements / SampleHandler.swift / Dart 常量」三处一致就能工作，
# 真正提交审核前请到开发者后台把这个 group 注册好。
DEFAULT_APP_GROUP = None

# Android 需要的权限。value 为 None 表示不带 maxSdkVersion。
ANDROID_PERMISSIONS = [
    ('android.permission.INTERNET', None),
    ('android.permission.ACCESS_NETWORK_STATE', None),
    ('android.permission.ACCESS_WIFI_STATE', None),
    ('android.permission.CHANGE_WIFI_STATE', None),
    # 音视频采集
    ('android.permission.CAMERA', None),
    ('android.permission.RECORD_AUDIO', None),
    ('android.permission.MODIFY_AUDIO_SETTINGS', None),
    # 蓝牙耳机
    ('android.permission.BLUETOOTH', None),
    ('android.permission.BLUETOOTH_CONNECT', None),
    # 通话中保持唤醒，避免息屏后音频被系统掐掉
    ('android.permission.WAKE_LOCK', None),
    # 读取设备标识（TRTC 用于区分设备）
    ('android.permission.READ_PHONE_STATE', None),
    # 屏幕共享前台服务：Android 14(API 34) 起 FOREGROUND_SERVICE_MEDIA_PROJECTION 必填
    ('android.permission.FOREGROUND_SERVICE', None),
    ('android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION', None),
    # 前台服务通知（Android 13+ 不授权则通知不显示）
    ('android.permission.POST_NOTIFICATIONS', None),
    # 聊天发图（Android 13+ 用细分权限，旧版本用 READ_EXTERNAL_STORAGE）
    ('android.permission.READ_MEDIA_IMAGES', None),
    ('android.permission.READ_MEDIA_VIDEO', None),
    ('android.permission.READ_EXTERNAL_STORAGE', '32'),
]

# minSdk 的下限。全部依赖里要求最高的是 24：
#   permission_handler_android / image_picker_android / shared_preferences_android
# 都声明了 minSdk = 24；而 Flutter 3.44 自己的默认值也是 24。
# 详见 patch_android_min_sdk() 的说明。
MIN_SDK_FLOOR = 24


def log(msg):
    print('  ' + msg)


def read(path):
    if not os.path.isfile(path):
        return None
    return io.open(path, encoding='utf-8', errors='replace').read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    io.open(path, 'w', encoding='utf-8', newline='\n').write(text)


def patch(path, pairs, label):
    """按 (正则, 替换) 列表改文件；只改第一个匹配。"""
    text = read(path)
    if text is None:
        log('!! 找不到 %s，跳过 %s' % (path, label))
        return False
    changed = False
    for pattern, repl in pairs:
        new, n = re.subn(pattern, repl, text, count=1)
        if n:
            text = new
            changed = True
    if changed:
        write(path, text)
        log('✓ %s' % label)
    else:
        log('- %s（无需改动）' % label)
    return changed


# ============================================================================
#  Android
# ============================================================================

def detect_android_package(gradle_path):
    """从 build.gradle / build.gradle.kts 里取 namespace 或 applicationId。"""
    text = read(gradle_path) or ''
    m = re.search(r'namespace\s*=?\s*["\']([\w.]+)["\']', text)
    if m:
        return m.group(1)
    m = re.search(r'applicationId\s*=?\s*["\']([\w.]+)["\']', text)
    if m:
        return m.group(1)
    return 'com.example.meeting_app'


def patch_android_manifest(path):
    text = read(path)
    if text is None:
        log('!! 找不到 AndroidManifest.xml')
        return

    # 1) 权限：插到 <manifest ...> 之后
    block = []
    for perm, maxsdk in ANDROID_PERMISSIONS:
        if ('android:name="%s"' % perm) in text:
            continue
        extra = (' android:maxSdkVersion="%s"' % maxsdk) if maxsdk else ''
        block.append('    <uses-permission android:name="%s"%s/>' % (perm, extra))
    if block:
        # 相机/麦克风声明为非必需，否则平板、无摄像头设备装不上
        block += [
            '    <uses-feature android:name="android.hardware.camera" android:required="false"/>',
            '    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false"/>',
            '    <uses-feature android:name="android.hardware.microphone" android:required="false"/>',
        ]
        text = re.sub(
            r'(<manifest[^>]*>\s*\n)',
            lambda m: m.group(1) + '\n'.join(block) + '\n',
            text, count=1)
        log('✓ Android 权限已补齐（%d 条）' % len(block))
    else:
        log('- Android 权限已存在')

    # 2) 明文 HTTP：后端是 http://192.168.x.x:5000，不放行会直接连不上
    m = re.search(r'<application\b[^>]*>', text)
    if m and 'usesCleartextTraffic' not in m.group(0):
        tag = m.group(0)
        new_tag = tag[:-1].rstrip() + '\n        android:usesCleartextTraffic="true">'
        text = text.replace(tag, new_tag, 1)
        log('✓ 已允许明文 HTTP（局域网后端必需）')

    # 3) 屏幕共享前台服务
    if 'ScreenShareService' not in text:
        svc = (
            '\n        <!--\n'
            '            屏幕共享前台服务。\n'
            '            Android 10+ 的 MediaProjection 必须跑在 foregroundServiceType="mediaProjection"\n'
            '            的前台服务里，否则 TRTC 在系统授权回调时会抛 SecurityException。\n'
            '            实现见 src/main/kotlin/**/ScreenShareService.kt\n'
            '        -->\n'
            '        <service\n'
            '            android:name=".ScreenShareService"\n'
            '            android:enabled="true"\n'
            '            android:exported="false"\n'
            '            android:foregroundServiceType="mediaProjection" />\n'
        )
        text = re.sub(r'(\n\s*</application>)', svc + r'\1', text, count=1)
        log('✓ 已注册 ScreenShareService（mediaProjection 前台服务）')

    write(path, text)


def patch_android_min_sdk(text, is_kts):
    """确保 minSdk 不低于依赖要求 —— 并且**绝不把它降下去**。

    为什么这里是「只升不降」而不是「统一写死某个值」：

      · Flutter 3.44 自己的 `flutter.minSdkVersion` 默认就是 24；
      · permission_handler_android / image_picker_android /
        shared_preferences_android 都声明 minSdk = 24。

    所以早期这里把它写死成 23，其实是一次**降级**，会让构建停在
    manifest 合并阶段，而且错误信息与真正的原因看起来毫无关系：

        uses-sdk:minSdkVersion 23 cannot be smaller than version 24
        declared in library [:permission_handler_android]

    那反过来写死 24 行不行？也不行 —— 哪天 Flutter 把默认值提到 26，
    写死的 24 又变成降级，同一个坑再踩一次。
    所以正确做法是**跟随 flutter.minSdkVersion**（Flutter 会保证它不低于
    生态要求），只在遇到更低的字面量时才抬高。
    """
    # 标准模板：minSdk = flutter.minSdkVersion —— 跟随 Flutter，什么都别动。
    if re.search(r'\bminSdk(?:Version)?\s*[= ]\s*flutter\.minSdkVersion', text):
        log('- minSdk 跟随 flutter.minSdkVersion（3.44 默认 24），满足全部依赖要求')
        return text

    pat = r'\bminSdk\s*=\s*(\d+)' if is_kts else r'\bminSdkVersion\s*=?\s*(\d+)'
    m = re.search(pat, text)
    if not m:
        log('- 没找到 minSdk 声明，跳过（请自行确认不低于 %d）' % MIN_SDK_FLOOR)
        return text

    cur = int(m.group(1))
    if cur >= MIN_SDK_FLOOR:
        log('- minSdk 已是 %d，无需改动' % cur)
        return text

    text = text[:m.start(1)] + str(MIN_SDK_FLOOR) + text[m.end(1):]
    log('✓ minSdk 由 %d 抬到 %d（permission_handler 等依赖要求 24）'
        % (cur, MIN_SDK_FLOOR))
    return text


def patch_android_gradle(path):
    text = read(path)
    if text is None:
        log('!! 找不到 build.gradle(.kts)')
        return
    is_kts = path.endswith('.kts')

    text = patch_android_min_sdk(text, is_kts)

    # release 开混淆 + 挂 proguard 规则
    if 'proguard-rules.pro' not in text:
        comment = '            // TRTC 靠反射找回调，不保留会在 release 里「本地画面正常、远端全黑且无报错」'
        if is_kts:
            extra = '\n'.join([
                comment,
                '            isMinifyEnabled = true',
                '            isShrinkResources = true',
                '            proguardFiles(',
                '                getDefaultProguardFile("proguard-android-optimize.txt"),',
                '                "proguard-rules.pro"',
                '            )',
            ])
        else:
            extra = '\n'.join([
                comment,
                '            minifyEnabled true',
                '            shrinkResources true',
                "            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'",
            ])
        text, n = re.subn(r'(buildTypes\s*\{\s*\n\s*release\s*\{)',
                          lambda m: m.group(1) + '\n' + extra,
                          text, count=1)
        if n:
            log('✓ release 已开启混淆并挂上 proguard-rules.pro')

    # 只打包真实设备需要的 ABI，包体积能少一半
    if 'abiFilters' not in text:
        if is_kts:
            extra = '\n'.join([
                '        ndk {',
                '            // x86/x86_64 只有模拟器用得上，release 不带',
                '            abiFilters += listOf("armeabi-v7a", "arm64-v8a")',
                '        }',
            ])
        else:
            extra = '\n'.join([
                '        ndk {',
                '            // x86/x86_64 只有模拟器用得上，release 不带',
                "            abiFilters 'armeabi-v7a', 'arm64-v8a'",
                '        }',
            ])
        text, n = re.subn(r'(defaultConfig\s*\{)',
                          lambda m: m.group(1) + '\n' + extra,
                          text, count=1)
        if n:
            log('✓ 已限制 ABI 为 armeabi-v7a / arm64-v8a')

    write(path, text)


def apply_android():
    print('\n[Android]')
    android_dir = os.path.join(APP_DIR, 'android')
    if not os.path.isdir(android_dir):
        log('!! 没有 android/ 目录，请先执行 flutter create（或去掉 --no-create）')
        return

    gradle = None
    for name in ('build.gradle.kts', 'build.gradle'):
        p = os.path.join(android_dir, 'app', name)
        if os.path.isfile(p):
            gradle = p
            break
    if gradle is None:
        log('!! 找不到 android/app/build.gradle(.kts)')
        return

    pkg = detect_android_package(gradle)
    log('包名: %s' % pkg)

    patch_android_manifest(os.path.join(android_dir, 'app', 'src', 'main', 'AndroidManifest.xml'))
    patch_android_gradle(gradle)

    # proguard 规则
    src_pro = os.path.join(HERE, 'android', 'proguard-rules.pro')
    dst_pro = os.path.join(android_dir, 'app', 'proguard-rules.pro')
    if os.path.isfile(src_pro) and not os.path.isfile(dst_pro):
        shutil.copyfile(src_pro, dst_pro)
        log('✓ 已写入 android/app/proguard-rules.pro')

    # Kotlin 源码（包路径要和包名一致）
    kotlin_root = os.path.join(android_dir, 'app', 'src', 'main', 'kotlin')
    # 有些工程是 java/ 目录
    if not os.path.isdir(kotlin_root):
        java_root = os.path.join(android_dir, 'app', 'src', 'main', 'java')
        kotlin_root = java_root if os.path.isdir(java_root) else kotlin_root
    pkg_dir = os.path.join(kotlin_root, *pkg.split('.'))

    for src_name, dst_name in (('MainActivity.kt', 'MainActivity.kt'),
                               ('ScreenShareService.kt', 'ScreenShareService.kt')):
        tpl = read(os.path.join(HERE, 'android', src_name))
        if tpl is None:
            continue
        dst = os.path.join(pkg_dir, dst_name)
        body = tpl.replace('__ANDROID_PACKAGE__', pkg)
        old = read(dst)
        if old == body:
            log('- %s 已是最新' % dst_name)
        else:
            write(dst, body)
            log('✓ 已写入 %s（%s）' % (dst_name, os.path.relpath(dst, APP_DIR)))

    # gradle.properties
    gp = os.path.join(android_dir, 'gradle.properties')
    props = read(gp)
    if props is not None and 'android.useAndroidX' not in props:
        write(gp, props.rstrip() + '\nandroid.useAndroidX=true\nandroid.enableJetifier=true\n')
        log('✓ 已开启 AndroidX')


# ============================================================================
#  iOS
# ============================================================================

def plist_add(path, entries):
    """往 plist 的顶层 <dict> 里插入若干 <key>/<value>。"""
    text = read(path)
    if text is None:
        log('!! 找不到 %s' % path)
        return
    added = []
    for key, value in entries:
        if ('<key>%s</key>' % key) in text:
            continue
        added.append('\t<key>%s</key>\n\t<string>%s</string>' % (key, value))

    # CFA 背景模式：屏幕共享期间要保持采集
    if '<key>UIBackgroundModes</key>' not in text:
        added.append(
            '\t<key>UIBackgroundModes</key>\n'
            '\t<array>\n'
            '\t\t<string>audio</string>\n'
            '\t\t<string>voip</string>\n'
            '\t</array>'
        )

    if not added:
        log('- Info.plist 无需改动')
        return

    # 插在第一个 <dict> 之后
    m = re.search(r'(<dict>\s*\n)', text)
    if not m:
        log('!! Info.plist 结构异常，请手工添加')
        return
    text = text[:m.end()] + '\n'.join(added) + '\n' + text[m.end():]
    write(path, text)
    log('✓ Info.plist 已补 %d 项' % len(added))


#: Flutter 3.44 的 ios Podfile 模板。
#:
#: 为什么要内嵌一份：`flutter create --platforms=ios` **不会**生成 Podfile ——
#: 它在 flutter_tools 里叫 setupPodfile()，只在 build / pod 相关流程中才被调用。
#: 而我们要往 Podfile 里追加录屏扩展 target，所以必须先把它准备好。
#: 这份内容取自 packages/flutter_tools/templates/cocoapods/Podfile-ios（3.44.9）。
PODFILE_TEMPLATE = '''# Uncomment this line to define a global platform for your project
# platform :ios, '13.0'

# CocoaPods analytics sends network stats synchronously affecting flutter build latency.
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. If you're running pod install manually, make sure flutter pub get is executed first"
  end

  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. Try deleting Generated.xcconfig, then run flutter pub get"
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
'''


def ensure_podfile(ios_dir):
    """确保 ios/Podfile 存在，返回它的路径。

    优先用 Flutter 安装目录里自带的那份模板（这样能跟随 Flutter 版本），
    找不到时用内嵌的兜底 —— CI 上装的是固定版本的 Flutter，两者等价。
    """
    podfile = os.path.join(ios_dir, 'Podfile')
    if os.path.isfile(podfile):
        return podfile

    template = None
    for root in (os.environ.get('FLUTTER_ROOT'), '/opt/flutter', os.path.expanduser('~/flutter')):
        if not root:
            continue
        candidate = os.path.join(root, 'packages', 'flutter_tools',
                                 'templates', 'cocoapods', 'Podfile-ios')
        t = read(candidate)
        if t:
            template = t
            log('✓ ios/Podfile 不存在，已从 %s 生成' % candidate)
            break
    if template is None:
        template = PODFILE_TEMPLATE
        log('✓ ios/Podfile 不存在，已用内嵌模板生成（Flutter 3.44 版）')

    write(podfile, template)
    return podfile


def apply_ios():
    print('\n[iOS]')
    ios_dir = os.path.join(APP_DIR, 'ios')
    if not os.path.isdir(ios_dir):
        log('!! 没有 ios/ 目录，请先执行 flutter create（或去掉 --no-create）')
        return

    runner_plist = os.path.join(ios_dir, 'Runner', 'Info.plist')
    # 缺了这几个描述，一调相机/麦克风 App 会被系统直接杀掉（不是弹框拒绝，是闪退）
    plist_add(runner_plist, [
        ('NSCameraUsageDescription', '会议需要使用摄像头，用于采集并发送你的视频画面'),
        ('NSMicrophoneUsageDescription', '会议需要使用麦克风，用于采集并发送你的语音'),
        ('NSPhotoLibraryUsageDescription', '用于选择图片作为头像或在会议聊天中发送'),
        ('NSPhotoLibraryAddUsageDescription', '用于把会议中的图片保存到相册'),
        ('NSLocalNetworkUsageDescription', '用于在局域网内直连会议服务器（开发环境）'),
        ('NSBluetoothAlwaysUsageDescription', '用于连接蓝牙耳机进行会议通话'),
    ])

    # App Group：主 App 的 entitlements
    runner_ent = os.path.join(ios_dir, 'Runner', 'Runner.entitlements')
    tpl = read(os.path.join(HERE, 'ios', 'Runner.entitlements'))
    if tpl:
        body = tpl.replace('group.com.example.meetingApp', APP_GROUP)
        write(runner_ent, body)
        log('✓ ios/Runner/Runner.entitlements（App Group=%s）' % APP_GROUP)

    # 录屏扩展源码，放进 ios/ 下备用
    ext_dir = os.path.join(ios_dir, 'BroadcastExtension')
    for name in ('SampleHandler.swift', 'BroadcastExtension.entitlements', 'Info.plist'):
        src = os.path.join(HERE, 'ios', 'BroadcastExtension', name)
        t = read(src)
        if t is None:
            continue
        dst_name = 'Info.plist' if name == 'Info.plist' else name
        write(os.path.join(ext_dir, dst_name),
              t.replace('group.com.example.meetingApp', APP_GROUP))
    log('✓ ios/BroadcastExtension/（3 个文件）')

    # Podfile（flutter create 不会生成它，见 ensure_podfile 的说明）
    podfile = ensure_podfile(ios_dir)
    text = read(podfile)
    if text is not None:
        # Flutter 3.44 已经把最低 iOS 版本提到 13.0，低于这个值 pod install 会报错。
        # 系统级屏幕共享本身只要 iOS 11+，跟着 Flutter 走 13.0 即可。
        #
        # 注意模板里那行是**被注释掉的**（`# platform :ios, '13.0'`），
        # 所以要连注释形式一起匹配、原地替换 —— 否则会在开头另插一行，
        # 变成"生效的一行 + 注释的一行"，虽然能跑但很迷惑。
        m = re.search(r"^#?\s*platform :ios.*$", text, re.M)
        if m:
            text = text[:m.start()] + "platform :ios, '13.0'" + text[m.end():]
        else:
            text = "platform :ios, '13.0'\n" + text
        if 'TXLiteAVSDK_Professional/ReplayKitExt' not in text:
            # 直接写**生效**的配置，不再给注释模板。
            # 扩展 target 由 platform/ios/add_broadcast_extension.py 自动创建，
            # 所以不需要再让人手工去 Xcode 里点。两步的顺序不能颠倒：
            #     1) add_broadcast_extension.py（先有 target）
            #     2) pod install（CocoaPods 只认识已存在的 target）
            # CI 里就是这么排的。
            text = text.rstrip() + '''

# ============================================================================
#  录屏扩展 Target 的依赖（TRTC 系统级屏幕共享必需）
#
#  对应的 Xcode target 由 platform/ios/add_broadcast_extension.py 自动创建。
#  漏了这段的后果：扩展里 `import TXLiteAVSDK_ReplayKitExt` 找不到模块，
#  编译期直接失败（这类报错还算清楚，不属于难查的那一类）。
# ============================================================================
target 'BroadcastExtension' do
  inherit! :search_paths

  # iOS 原生 SDK 的依赖链是：
  #   tencent_rtc_sdk  →  super_player/professional  →  TXLiteAVSDK_Professional
  # 所以这里直接引用 TXLiteAVSDK_Professional 的 ReplayKitExt 子规格即可。
  #
  # ⚠️ 不要写死版本号：同一个 Podfile 内 CocoaPods 会把同名 pod 的子规格
  #    统一解析到同一个版本，主 App 与扩展自然一致。一旦写死，日后主 App
  #    侧升级就会产生版本错配，扩展启动时报 TXReplayKitExtReason.versionMismatch，
  #    典型现象是「点了开始共享，屏幕顶部变红但会议里谁都没看到画面」。
  pod 'TXLiteAVSDK_Professional/ReplayKitExt'
end
'''
        # permission_handler：iOS 侧每个权限都由一个 PERMISSION_* 宏守卫。
        # 不开对应宏，Dart 的 Permission.camera.request() 会**静默失效**
        # （永远返回 denied），现象是「系统权限弹窗根本不出现，直接就没权限」。
        # 官方要求 CocoaPods 用户在 Podfile 的 GCC_PREPROCESSOR_DEFINITIONS 里自己设置。
        if 'PERMISSION_CAMERA' not in text:
            snippet = '\n'.join([
                '',
                '    # ---- permission_handler：只编译本 App 真正用到的权限 ----',
                '    #',
                '    # 不开对应宏，Dart 的 Permission.xxx.request() 会静默失效（永远 denied），',
                '    # 现象是「系统弹窗根本不出现，直接就没权限」，很容易查错方向。',
                '    # 其余权限显式关闭：把未声明 NS*UsageDescription 的权限代码编译进来，',
                '    # 上架审核会被打回（ITMS-90683）。',
                "    target.build_configurations.each do |config|",
                "      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [",
                "        '$(inherited)',",
                "        'PERMISSION_CAMERA=1',",
                "        'PERMISSION_MICROPHONE=1',",
                "        'PERMISSION_NOTIFICATIONS=1',",
                "        'PERMISSION_EVENTS=0',",
                "        'PERMISSION_EVENTS_FULL_ACCESS=0',",
                "        'PERMISSION_REMINDERS=0',",
                "        'PERMISSION_CONTACTS=0',",
                "        'PERMISSION_SPEECH_RECOGNIZER=0',",
                "        'PERMISSION_PHOTOS=0',",
                "        'PERMISSION_LOCATION=0',",
                "        'PERMISSION_MEDIA_LIBRARY=0',",
                "        'PERMISSION_SENSORS=0',",
                "        'PERMISSION_BLUETOOTH=0',",
                "        'PERMISSION_APP_TRACKING_TRANSPARENCY=0',",
                "        'PERMISSION_CRITICAL_ALERTS=0',",
                "        'PERMISSION_ASSISTANT=0',",
                '      ]',
                '    end',
                '',
            ])
            text, n = re.subn(
                r'(\n    flutter_additional_ios_build_settings\(target\)\n)',
                lambda m: m.group(1) + snippet,
                text, count=1)
            if n:
                log('✓ Podfile：已打开 相机/麦克风/通知 权限宏（其余关闭）')
            else:
                log('!! Podfile 里没找到 flutter_additional_ios_build_settings(target)，'
                    '权限宏未注入 —— 请按 platform/README.md 第 6.0 节手工添加')

        write(podfile, text)
        log("✓ Podfile 已就绪（platform :ios, '13.0' + 权限宏 + 录屏扩展 target 配置）")
    else:
        log('!! 找不到 ios/Podfile')


# ============================================================================
#  main
# ============================================================================

def sync_app_group_to_dart(app_group):
    """把 App Group 同步写进 lib/core/app_config.dart。

    这个字符串必须与 entitlements、SampleHandler.swift 完全一致，大小写都不能差。
    「脚本改了 entitlements 却忘了改 Dart 常量」是本项目最难查的一类问题：
    控制中心里录屏图标正常、手机顶部也变红，但会议里谁都没看到画面 ——
    因为扩展进程与主进程没挂在同一个共享容器上，采到的帧主进程收不到。
    所以这里直接自动同步，不再依赖使用者记得手改。
    """
    path = os.path.join(APP_DIR, 'lib', 'core', 'app_config.dart')
    text = read(path)
    if text is None:
        log('!! 找不到 lib/core/app_config.dart，跳过 App Group 同步')
        return
    new, n = re.subn(
        r"(static const String iosAppGroup = ')[^']*(';)",
        lambda m: m.group(1) + app_group + m.group(2),
        text, count=1)
    if n == 0:
        log('!! app_config.dart 里没找到 iosAppGroup 常量，请手工确认')
        return
    if new != text:
        write(path, new)
        log('✓ app_config.dart 的 iosAppGroup 已同步为 %s' % app_group)
    else:
        log('- app_config.dart 的 iosAppGroup 已是 %s' % app_group)


def run_flutter_create(org):
    print('\n[flutter create]')
    args = [
        'flutter', 'create',
        '--platforms=android,ios',
        '--org', org,
        '--project-name', 'meeting_app',
        '.',
    ]
    log('$ ' + ' '.join(args))
    try:
        r = subprocess.run(args, cwd=APP_DIR)
        if r.returncode != 0:
            log('!! flutter create 失败（exit=%d），请自行执行后加 --no-create 重跑' % r.returncode)
            return False
        return True
    except OSError as e:
        log('!! 无法执行 flutter：%s' % e)
        log('   请确认 flutter 在 PATH 里，或手工执行：')
        log('   flutter create --platforms=android,ios --org %s --project-name meeting_app .' % org)
        return False


def main():
    global APP_GROUP

    ap = argparse.ArgumentParser()
    ap.add_argument('--no-create', action='store_true',
                    help='跳过 flutter create，只打补丁')
    ap.add_argument('--org', default=DEFAULT_ORG, help='反向域名前缀，默认 com.example')
    ap.add_argument('--app-group', default=None,
                    help='iOS App Group（默认从 --org 推导为 group.<org>.meetingApp）')
    args = ap.parse_args()

    APP_GROUP = args.app_group or ('group.%s.meetingApp' % args.org.strip('.'))

    print('=' * 70)
    print(' 会议 App 平台配置补丁')
    print(' 工程目录: %s' % APP_DIR)
    print(' App Group: %s' % APP_GROUP)
    print('=' * 70)

    if not args.no_create:
        run_flutter_create(args.org)

    # Dart 常量先同步：它不依赖 ios/ 目录是否存在，且是与 entitlements 对齐的关键
    sync_app_group_to_dart(APP_GROUP)

    apply_android()
    apply_ios()

    print('\n' + '=' * 70)
    print(' 完成。后续步骤：')
    print('=' * 70)
    print('''
 1) Android：直接构建即可
      flutter build apk --release

 2) iOS：**还要再跑一步** —— 在 Xcode 工程里建出录屏扩展 Target
      python3 platform/ios/add_broadcast_extension.py
      cd ios && pod install
      flutter build ipa --release

    iOS 的系统级屏幕共享（能录到别的 App）必须由一个**独立的 Broadcast
    Upload Extension 进程**采集屏幕，再通过 App Group 把画面交给主 App。
    这个扩展必须以独立 Target 的形式存在于 Runner.xcodeproj 里，光有
    SampleHandler.swift 源码是不会被编译的。

    本脚本只负责把源码、Info.plist、entitlements、Podfile 准备好；
    建 Target 是 add_broadcast_extension.py 的活（顺序不能颠倒，
    因为 CocoaPods 只认识「已存在的 target」）。
''')
    if not os.path.isdir(os.path.join(APP_DIR, 'ios')):
        print('    ⚠️ 当前还没有 ios/ 目录 —— 上面的 iOS 步骤要先 flutter create 生成工程。')


if __name__ == '__main__':
    APP_GROUP = None  # 由 main() 按 --org / --app-group 推导
    main()
