# replay_kit_launcher（本地 fork）

**用途**：弹出 iOS 系统的 `RPSystemBroadcastPickerView`，让用户能"点一下"就开始
系统级屏幕共享。

## 为什么需要它

从 **iOS 11** 起，系统**不允许 App 自己启动系统级录屏**（只能录本 App 画面的
in-app 录制不受此限），必须由用户主动触发。

而 TRTC 的

```dart
TRTCCloud().startScreenCaptureByReplaykit(TRTCVideoStreamType.sub, encParam, appGroup);
```

**只是让 SDK 进入「等待共享数据」的状态 —— 它不弹任何界面。**

两者叠加的结果：没有这个触发入口，用户点了「共享屏幕」之后界面上
**什么都不会发生**，日志里也没有任何错误。腾讯官方文档对此的原文是：

> 屏幕分享就需要用户在 iOS 系统的控制中心，通过长按录屏按钮来触发

官方给出的推荐方案就是引入 `replay_kit_launcher` 这个插件。

## 为什么要 fork，而不是直接依赖 pub.dev 上的同名包

pub.dev 上的 `replay_kit_launcher` 最后一版是 **2022-02-09 的 1.0.0**，
`environment.sdk: '>=2.12.0 <3.0.0'` —— 在 Dart 3 上**直接解析失败**，
`pub get` 就过不去。

因此这里做了本地 fork，改动有三处：

1. **`pubspec.yaml`**：SDK 约束改成 `^3.0.0`；插件平台只声明 iOS
   （Android 的屏幕共享走 `MediaProjection` + 前台服务，不需要这个）。
2. **`ReplayKitLauncherPlugin.m`** 增加了**双路径容错**：
   - 路径 1（首选）：遍历 `RPSystemBroadcastPickerView` 的子视图，
     找到那个内部 `UIButton` 并主动触发，用户不用再点一次；
   - 路径 2（兜底）：找不到按钮就把选择器**显示到屏幕上**，让用户自己点。
     Apple 并未承诺过上述子视图结构稳定，所以必须有这条兜底。
3. **`RKLKeyWindow()`**：处理 iOS 13+ 的多 scene 情况
   （优先 `connectedScenes`，回退 `keyWindow`），否则在分屏 / 多窗口场景下
   可能往一个不可见的 window 上挂视图。

## 接口

```dart
static Future<bool> launch(String extensionName)
```

`extensionName` 是 Broadcast Upload Extension 的 **Product Name**
（即 `BroadcastExtension.appex` 的文件名）。本工程里传的是
`AppConfig.iosBroadcastExtension`。

⚠️ **名字传错的表现**：系统选择器**能弹出来**，但里面**一片空白**，
列不出任何可选扩展，而且不会有任何报错。它必须与 Xcode 里那个 target 的
Product Name 一致。

## 调用位置

`lib/services/rtc_service.dart` 的 `_launchIosBroadcastPicker()`，
在 `startScreenCaptureByReplaykit(...)` 之后调用。

返回值 / 异常会区分两类完全不同的问题，方便排查：

- `MissingPluginException` → 构建问题（没执行 `pod install` 就构建了）
- 返回 `false` → 配置问题（扩展 Target 没建，或名字不一致）

## 许可

MIT。核心思路参考 pub.dev 的 `replay_kit_launcher`
（Copyright (c) 2022 Zegocloud, MIT）。详见 `LICENSE`。
