#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""预检：依赖要求的 Android SDK 版本，是否超出 CI 能给的范围。

为什么需要这个脚本
──────────────────
某个依赖若把 compileSdk 抬到比本项目更高的值，而 CI 的 Android SDK 仓库对
较新版本只提供「次要版本」包（安装到 platforms/android-N.0），Gradle 却是按
android-N 去找平台的，于是构建会报出一句和真实原因**毫无关系**的话：

    Could not find target with hash string 'android-37'

真实案例：permission_handler_android 14.1.0 的 build.gradle.kts 写死
`compileSdk = 37`，且源码用了 API 37 才有的
`Manifest.permission.ACCESS_LOCAL_NETWORK` —— 它出现在 switch 的 case 标签上，
而 case 标签必须是编译期常量，所以**没法**靠「把编译版本降回 36」绕开。
两条叠加，构建必然撞上上面那条报错，而报错文本里既没有包名也没有 API 37 字样。

本脚本把这种情况翻译成人话，并且**只提醒、不中断构建** —— 万一哪天 SDK 仓库
能正常提供该平台，就不该被这里挡住。所以调用方要写成：

    python3 platform/precheck_android_sdk.py || true

用法：在工程根目录（即含 .dart_tool/package_config.json 的那一层）执行。
"""

import json
import os
import re
import sys
from urllib.parse import unquote, urlparse

# compileSdk = 37 / compileSdkVersion 35（groovy）/ compileSdkVersion flutter.xxx（取不到数字）
COMPILE_SDK_RE = re.compile(r'compileSdk[A-Za-z]*\s*[= ]\s*(\d+)')

# Flutter 模板写的是 `compileSdk = flutter.compileSdkVersion`，字面上没有数字，
# 这时只能回 Flutter 自己的默认值。
FLUTTER_EXT_RE = re.compile(r'compileSdkVersion:\s*Int\s*=\s*(\d+)')

FALLBACK_SDK = 36


def _read(path):
    try:
        with open(path, encoding='utf-8') as f:
            return f.read()
    except (IOError, OSError):
        return None


def app_compile_sdk(root):
    """返回 (compileSdk 值, 这个值的来源说明)。"""
    for rel in ('android/app/build.gradle.kts', 'android/app/build.gradle'):
        text = _read(os.path.join(root, rel))
        if text:
            m = COMPILE_SDK_RE.search(text)
            if m:
                return int(m.group(1)), rel

    # 模板里是 flutter.compileSdkVersion，直接读 Flutter 的默认值
    flutter_root = os.environ.get('FLUTTER_ROOT', '')
    if flutter_root:
        ext = os.path.join(
            flutter_root,
            'packages', 'flutter_tools', 'gradle',
            'src', 'main', 'kotlin', 'FlutterExtension.kt',
        )
        text = _read(ext)
        if text:
            m = FLUTTER_EXT_RE.search(text)
            if m:
                return int(m.group(1)), 'Flutter 默认值（FlutterExtension.kt）'

    return FALLBACK_SDK, '兜底值'


def resolved_packages(root):
    """只取本次**实际解析到**的包。

    不能直接扫 ~/.pub-cache：那里面会留着旧版本目录，
    刚降下去的版本会被旧目录重新报出来，属误报。
    """
    text = _read(os.path.join(root, '.dart_tool', 'package_config.json'))
    if text is None:
        return None
    uris = []
    for pkg in json.loads(text).get('packages', []):
        uri = pkg.get('rootUri') or ''
        if not uri:
            continue
        if uri.startswith('file:'):
            path = unquote(urlparse(uri).path)
            # Windows 上 urlparse 会给出 /C:/x，去掉多余的前导斜杠
            if re.match(r'^/[A-Za-z]:', path):
                path = path[1:]
        else:
            path = os.path.normpath(os.path.join(root, uri))
        uris.append((pkg.get('name') or '?', path))
    return uris


def plugin_compile_sdk(pkg_dir):
    for rel in ('android/build.gradle.kts', 'android/build.gradle'):
        text = _read(os.path.join(pkg_dir, rel))
        if text is None:
            continue
        m = COMPILE_SDK_RE.search(text)
        # 文件存在但没写死数字（用的是 flutter.compileSdkVersion）→ 跟随本项目，无需检查
        return int(m.group(1)) if m else None
    return None


def main():
    root = os.getcwd()
    app_sdk, source = app_compile_sdk(root)
    print('本项目 compileSdk = %d（来源：%s）' % (app_sdk, source))

    packages = resolved_packages(root)
    if packages is None:
        print('!! 找不到 .dart_tool/package_config.json，跳过预检（请先跑 flutter pub get）')
        return 0

    bad = []
    for name, path in packages:
        value = plugin_compile_sdk(path)
        if value is not None and value > app_sdk:
            bad.append((name, value))

    if not bad:
        print('所有依赖的 compileSdk 均不超过 %d，OK' % app_sdk)
        return 0

    line = '!! ' + '=' * 68
    print('')
    print(line)
    print('!! 以下依赖要求比本项目更高的 Android SDK：')
    for name, value in bad:
        print('!!   %-42s 需要 compileSdk %d' % (name, value))
    print('!!')
    print('!! 若构建稍后报 "Could not find target with hash string android-<N>"，')
    print('!! 原因就在这：CI 只装得到 android-<N>.0，而 Gradle 在找 android-<N>。')
    print('!! 处理办法：在 pubspec.yaml 把该依赖降到 compileSdk <= %d 的版本，' % app_sdk)
    print('!! 并在那里写清为什么不能升 —— 否则下次会被「顺手升级」踩回去。')
    print(line)
    print('')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:  # 预检永远不该影响构建
        print('预检脚本自身出错，已忽略：%r' % (exc,))
        sys.exit(0)
