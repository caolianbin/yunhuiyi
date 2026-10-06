# 平台配置与打包说明（Android / iOS）

会议 App 的 Flutter 工程。本文档解决一件事：**把它变成能装到手机上、且屏幕共享真正可用的 App。**

---

## 0. 为什么从 uni-app 换成了 Flutter

原因只有一个：**苹果端必须支持系统级屏幕共享**（能共享整个屏幕，别的 App 也录得到），  
而不只是"共享本应用的画面"。

|             | uni-app / HBuilderX                                                                      | Flutter                        |
| ----------- | ---------------------------------------------------------------------------------------- | ------------------------------ |
| iOS 系统级屏幕共享 | ❌ 做不到                                                                                    | ✅ 可以                           |
| 原因          | HBuilderX 云打包**无法往 iOS 工程里插入 Broadcast Upload Extension 这个独立 Target**。没有它，系统不给跨 App 录屏权限 | 工程本身就是标准 Xcode 工程，可以手工加 Target |

所以下面 iOS 那一节里"手工建 Target"不是偷懒没做自动化，而是**这一步物理上只能人工操作**。

---

## 1. 目录说明

```
app/
├── lib/                          Dart 源码（24 个文件）
│   ├── core/                     配置、会话、HTTP 客户端、主题、原生通道
│   ├── models/                   后端 DTO 映射
│   ├── services/                 REST / SignalR / TRTC 三个服务
│   ├── state/                    room_controller.dart —— 会议页的大脑
│   └── pages/                    页面
└── platform/                     ← 平台配置都在这里
    ├── apply.py                  一键打补丁脚本（幂等）
    ├── android/
    │   ├── MainActivity.kt           MethodChannel，控制前台服务
    │   ├── ScreenShareService.kt     屏幕共享前台服务（**必需**，见下）
    │   └── proguard-rules.pro        TRTC 混淆规则
    └── ios/
        ├── Runner.entitlements           主 App 的 App Group
        └── BroadcastExtension/
            ├── SampleHandler.swift       ReplayKit 采集实现
            ├── BroadcastExtension.entitlements
            └── Info.plist
```

---

## 2. 先决条件

```bash
flutter --version     # 本工程用的是 3.44.9 stable / Dart 3.12.2
```

`app/lib/core/app_config.dart` 里的 `defaultBaseUrl` 默认是 `http://192.168.1.100:5000`，  
**登录页右上角可以改**，改完存在本地，不用为了换 IP 重新打包。

TRTC 的 `SdkAppId` / `SecretKey` 已经在后端 `appsettings.json` 里配好了，  
客户端不需要填，登录后会通过 `/api/rtc/usersig` 拿到签名。

---

## 3. 生成平台工程 + 打补丁

```bash
cd app

# 3.1 生成 android/ 和 ios/ 目录
flutter create --platforms=android,ios --org com.example --project-name meeting_app .

# 3.2 打补丁（幂等，可重复执行）
python platform/apply.py --no-create
```

或者一步到位（脚本帮你跑 `flutter create`）：

```bash
python platform/apply.py --org com.example --app-group group.com.example.meetingApp
```



> **改了包名或 App Group 就要重新对齐三处**，见第 6 节。

补丁做完做了这些事：

**Android**

| 项目                                                              | 为什么                                                                |
| --------------------------------------------------------------- | ------------------------------------------------------------------ |
| 17 条权限 + 3 条 `uses-feature`                                     | 相机/麦克风/蓝牙/通知/录屏前台服务；`uses-feature` 设 `required=false`，否则无摄像头的平板装不上 |
| `android:usesCleartextTraffic="true"`                           | 后端是局域网 `http://`，Android 9+ 默认禁止明文，不加就是"连不上服务器"                    |
| `<service ... android:foregroundServiceType="mediaProjection">` | **屏幕共享的生死线**，见第 5 节                                                |
| `minSdk = 23`                                                   | TRTC 与 `permission_handler` 都需要运行时权限模型                             |
| release 开混淆 + `proguard-rules.pro`                              | 不保留 TRTC 的反射目标，会出现"本地画面正常、远端全黑且不报错"                                |
| `abiFilters` 只留 `armeabi-v7a` / `arm64-v8a`                     | 去掉模拟器用的 x86，包体积小一半                                                 |

**iOS**

| 项目                                           | 为什么                        |
| -------------------------------------------- | -------------------------- |
| `Info.plist` 补 6 条隐私描述 + `UIBackgroundModes` | 缺相机/麦克风描述不是"被拒绝"，是**直接闪退** |
| `Podfile` 注入 `PERMISSION_*` 宏                | permission_handler 的 iOS 权限开关，不配的话**权限弹窗根本不出现**，见下 |
| `Runner.entitlements`                        | App Group，跨进程通信            |
| `Podfile` → `platform :ios, '13.0'`          | Flutter 3.44 的最低要求         |
| `ios/BroadcastExtension/` 3 个文件              | 录屏扩展源码，等第 6 节放进 Xcode      |

### 3.1 权限：两块都不能少

会议要能**视频、语音**，前提是拿到 `CAMERA` 和 `RECORD_AUDIO`。这里有两个独立的坑：

**Android（运行时申请）**

`CAMERA` / `RECORD_AUDIO` 是危险权限，只在 Manifest 声明**不够**，必须运行时申请。
不申请的话 TRTC 会以这两个码静默失败，而且**不弹任何系统框**：

| 错误码      | 真实原因        | 用户看到的现象             |
| -------- | ----------- | -------------------- |
| `-1314`  | 没有相机权限      | 能进会议、能看到别人，自己黑屏      |
| `-1317`  | 没有麦克风权限     | 能进会议、能听别人，别人听不到你     |

> 这两个码值是对着官方错误码表核过的（`ERR_CAMERA_NOT_AUTHORIZED` / `ERR_MIC_NOT_AUTHORIZED`）。
> 早期文档里写的 `-100006` / `-100007` 在官方表里**并不对应**摄像头/麦克风权限，是误记，已更正。
> 顺带一提：`-1301`/`-1302` 是"打开设备失败"（驱动类问题，多见于桌面端），
> `-1316`/`-1319` 是"设备被别的 App 占用"，别和权限问题搞混。

代码里由 `lib/core/permissions.dart` 的 `AppPermissions.requestForMeeting()` 处理，
在 `RoomController.start()` 一进来就申请（用户点「加入会议」后立刻弹框，符合直觉）。
**权限被拒也照常进会议**——仍然可以看别人、听别人，只是本地音视频关闭。

**iOS（编译期宏）**

`permission_handler` 在 iOS 上把每个权限用 `PERMISSION_*` 宏守卫起来，
**CocoaPods 用户必须自己在 Podfile 里打开对应宏**（不开的话
`Permission.camera.request()` 会静默失效，永远返回 denied，
表现是"系统弹窗根本不出现，直接就没权限"，非常容易查错方向）。

本项目只打开三个：

```ruby
'PERMISSION_CAMERA=1',
'PERMISSION_MICROPHONE=1',
'PERMISSION_NOTIFICATIONS=1',
```

其余一律 `=0`。原因不只是省体积：把**没有声明对应 `NS*UsageDescription`** 的
权限代码编译进二进制，上架审核会被打回（`ITMS-90683`）。

`apply.py` 会自动把这段注入 Podfile 的 `post_install`，日志会打印
`✓ Podfile：已打开 相机/麦克风/通知 权限宏（其余关闭）`。
如果看到的是 `!! Podfile 里没找到 flutter_additional_ios_build_settings(target)`，
说明 Podfile 结构和你预期不同，需要手工把这段加进 `post_install` 块里。

> 权限被永久拒绝（勾了"不再询问"）时，App 会弹一条带**「去设置」**按钮的提示，
> 点了直接跳系统权限页。没有这个入口，用户误点一次就只能卸载重装。

---

## 4. 跑起来

```bash
cd app
flutter pub get
flutter devices

# Android 真机（USB 调试打开）
flutter run -d <device-id>
# 或直接出包
flutter build apk --debug
flutter build apk --release

# iOS 真机（需要 Xcode 登录 Apple ID；屏幕共享必须先做完第 6 节）
cd ios && pod install && cd ..
flutter run -d <device-id>
```

**iOS 一定要用真机**：模拟器没有 ReplayKit，屏幕共享在模拟器上永远测不出来。

---

## 5. Android 屏幕共享：为什么必须有个前台服务

这一节是本项目最容易踩、而且报错最难懂的地方。

Android 10（API 29）起，`MediaProjection` 必须运行在  
`foregroundServiceType="mediaProjection"` 的前台服务里。**TRTC 的 Android SDK 不会自己起这个服务。**  
如果直接调 `startScreenCapture`，会在系统授权回调那一刻直接崩：

```
java.lang.SecurityException: Media projections require a foreground service
of type ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
    at android.media.projection.MediaProjection.<init>(MediaProjection.java:58)
    at com.tencent.rtmp.video.TXScreenCapture$TXScreenCaptureAssistantActivity
       .onActivityResult(TXScreenCapture.java:45)
```

注意堆栈里的 `com.tencent.rtmp.video.TXScreenCapture` —— 这不是你的代码抛的，是 SDK 内部抛的，  
所以日志上看起来"跟我的代码没关系"，很容易查错方向。

所以本项目实现了 `ScreenShareService`，并且**严格按这个顺序**调用：

```
Dart 侧 _startShare()
   ├─ 1. PlatformChannel.startScreenShareService()   → 前台服务进入前台
   └─ 2. RtcService.startScreenCapture()             → 系统弹「开始录制或投放？」
                                                       用户同意后才真正开始采集
停止时反过来：stopScreenCapture() → stopScreenShareService()（清掉通知栏残留）
```

顺序反了（先采集再起服务）同样会崩。代码见：

- `platform/android/ScreenShareService.kt` —— 前台服务实现
- `platform/android/MainActivity.kt` —— MethodChannel `meeting_app/platform`
- `lib/core/platform_channel.dart` —— Dart 侧封装，iOS / 桌面端自动空操作
- `lib/services/rtc_service.dart` 的 `startScreenCapture()` —— 调用顺序

---

## 6. iOS 系统级屏幕共享：完整步骤

> 这一节决定"苹果端屏幕共享能不能用"。**必须全部做完**，少一步的表现各不相同，  
> 我在每步后面标了"漏了会怎样"，方便对照排查。

### 6.1 在 Apple 开发者后台创建 App Group

1. 登录 <https://developer.apple.com> → **Certificates, IDs & Profiles**
2. 左侧选 **Identifiers** → 右上角 **+** → 选 **App Groups** → Continue
3. Description 随意；**Identifier 填 `group.com.example.meetingApp`**  
   （要和 `lib/core/app_config.dart` 的 `AppConfig.iosAppGroup` 一字不差）
4. Continue → Register
5. 回到 Identifiers → 左上角切到 **App IDs** → 点主 App 的 App ID  
   （形如 `com.example.meetingApp`）→ 勾上 **App Groups** → Edit → 选中刚建的 group → Continue → Save
6. **对录屏扩展的 App ID 重复第 5 步**  
   （扩展的 App ID 是 `com.example.meetingApp.BroadcastExtension`，第一次建 Target 后才会出现）
7. **重新下载 Provisioning Profile** 并装到 Xcode

> 漏了会怎样：控制中心显示在录屏，但会议里所有人都看不到你的屏幕。  
> （扩展采集到了帧，主进程收不到 —— 因为两个沙盒没有共享容器。）
>
> ⚠️ 别信"接口传 null 也能跑"这句话。本工程已核实过插件源码：
> Dart 桥接层是 `'appGroup': appGroup ?? ""`，**null 会被转成空串**，
> 空串能通过 iOS 侧的 `as? String` 类型检查、也真的会调进原生 SDK ——
> 于是变成"不报任何错、就是不传画面"，是最难查的一类失败。
> 所以本工程在 `AppConfig.iosAppGroup` 为空时**直接抛错**，宁可报错也不静默。
>
> 好消息：这个值现在由 `apply.py` 自动同步（见第 7 节），只要跑了脚本就不会不一致。

### 6.2 加 Broadcast Upload Extension Target

1. 打开 `app/ios/Runner.xcworkspace`（⚠️ 是 `.xcworkspace` 不是 `.xcodeproj`）
2. 菜单 **File > New > Target...** → 选 **Broadcast Upload Extension**
3. 填写：
   - Product Name: **`BroadcastExtension`**（名字要和第 3 节 Podfile 注释里的一致）
   - Language: **Swift**
   - **不要**勾 "Include UI Extension"
4. Finish → 弹出 "Activate scheme?" 选 **Activate**

### 6.3 替换 SampleHandler

Xcode 会自动生成一个 `SampleHandler.swift`，**用 `platform/ios/BroadcastExtension/SampleHandler.swift` 整个覆盖它**。

也可以用命令行（把路径换成你的工程）：

```bash
cp app/platform/ios/BroadcastExtension/SampleHandler.swift \
   app/ios/BroadcastExtension/SampleHandler.swift
cp app/platform/ios/BroadcastExtension/Info.plist \
   app/ios/BroadcastExtension/Info.plist
```

⚠️ 覆盖后确认 `SampleHandler.swift` 里的常量：

```swift
let APPGROUP = "group.com.example.meetingApp"   // ← 必须和 6.1 建的一致
```

### 6.4 挂上 App Group 能力（扩展 + 主 App 都要）

对 **BroadcastExtension** target：

1. 选中 target → **Signing & Capabilities** → **+ Capability** → 双击 **App Groups**
2. 在生成的 `BroadcastExtension.entitlements` 的 App Groups 里 **+** 填 `group.com.example.meetingApp`

对 **Runner** target 重复同样两步。

> 可以直接用仓库里准备好的文件覆盖（已经填好 group）：
>
> ```bash
> cp app/platform/ios/Runner.entitlements app/ios/Runner/Runner.entitlements
> cp app/platform/ios/BroadcastExtension/BroadcastExtension.entitlements \
>    app/ios/BroadcastExtension/BroadcastExtension.entitlements
> ```
>
> 覆盖后要确认 Xcode 的 **Build Settings > Code Signing Entitlements** 分别指向这两个文件。

### 6.5 给扩展配依赖

打开 `app/ios/Podfile`，**取消注释**第 3 节脚本追加的那一段：

```ruby
target 'BroadcastExtension' do
  inherit! :search_paths
  pod 'TXLiteAVSDK_Professional/ReplayKitExt'
end
```

然后：

```bash
cd app/ios && pod install
```

> ⚠️ **不要写死版本号**，这一点很反直觉但很重要。
>
> iOS 原生 SDK 的依赖链是：
>
> ```
> tencent_rtc_sdk  →  super_player/professional  →  TXLiteAVSDK_Professional
> ```
>
> 也就是说主 App 侧的 `TXLiteAVSDK_Professional` 是**不带版本号**声明的
> （由 `super_player` 决定具体版本）。同一个 Podfile 里，CocoaPods 会把
> **同一个 pod 的不同子规格统一解析到同一个版本**，所以扩展里的
> `TXLiteAVSDK_Professional/ReplayKitExt` 会**自动**和主 App 用同一版本。
>
> 一旦你手工写死一个版本号，主 App 升级时就会出现错配，扩展启动时报
> `TXReplayKitExtReason.versionMismatch`（"集成错误（SDK 版本号不相符合）"）。
>
> 漏了会怎样：`pod install` 后编译时报 `No such module 'TXLiteAVSDK_ReplayKitExt'`。

### 6.6 让扩展随主 App 一起打包

选中 **Runner** target → **Build Phases** → **+** → **New Copy Files Phase**：

- Destination: **PlugIns**
- 把 **BroadcastExtension.appex** 拖进去
- 勾上 **Code Sign On Copy**

> 漏了会怎样：App 装到手机上，控制中心的"屏幕录制"列表里**根本找不到你的 App**。

### 6.7 触发共享：为什么还要一个本地插件

这一步是"点了共享屏幕没反应"的**真正原因**，单独讲清楚。

**iOS 从 11 起不允许 App 自己启动系统级录屏。** 而 TRTC 的

```dart
cloud.startScreenCaptureByReplaykit(TRTCVideoStreamType.sub, enc, appGroup);
```

**只是让 SDK 进入「等待共享数据」的状态 —— 它不弹任何界面。**
腾讯官方文档原话是："屏幕分享就需要用户在 iOS 系统的控制中心，通过长按录屏按钮来触发"。

所以如果不给用户一个入口，现象就是：点了「共享」→ 什么也没发生 → 日志里一个错都没有。

本工程的做法是引入 `packages/replay_kit_launcher/`（**本地 fork**，见该目录内的说明），
在 `startScreenCaptureByReplaykit` 之后弹出系统的 `RPSystemBroadcastPickerView`：

```dart
// lib/services/rtc_service.dart
cloud.startScreenCaptureByReplaykit(TRTCVideoStreamType.sub, enc, appGroup);
await _launchIosBroadcastPicker();   // ← 弹系统选择器，用户点一下才开始
```

> 为什么是本地 fork 而不是 pub.dev 上的 `replay_kit_launcher`：
> 那个包最后一版是 2022-02-09 的 1.0.0，`environment.sdk: '>=2.12.0 <3.0.0'`，
> 在 Dart 3 上**直接解析失败**。fork 里除了改 SDK 约束，还补了多 scene 取 keyWindow
> 和"找不到按钮就退化成把系统按钮显示出来"的兜底路径。

⚠️ **插件里传的扩展名必须与 6.2 的 Product Name 一致**：

```dart
// lib/core/app_config.dart
static const String iosBroadcastExtension = 'BroadcastExtension';
```

传错的表现很迷惑：系统选择器弹出来了，但里面**一片空白**，列不出任何可选扩展。

### 6.8 验证

> 注意：不需要（也不应该）再让用户自己去控制中心长按录屏按钮了 ——
> 点 App 里的「共享屏幕」就会自动弹系统选择器。控制中心那条路是可选的备用方案。

1. 真机运行 App，进会议，点底部工具栏的**共享屏幕**按钮
2. 应**自动弹出**系统选择器（`RPSystemBroadcastPickerView`）
3. 列表里应出现 **会议屏幕共享**（就是 6.2 里的 Product Name / Info.plist 的 CFBundleDisplayName）
4. 选中它 → 开始直播 → 系统顶部变红
5. 会议里其他人应立刻看到你的屏幕
6. 回到 App，底部「共享」按钮应已变成 **停止共享**（状态由 `onScreenCaptureStarted` 回调驱动）

**排查对照表**

| 现象                        | 原因                                                          |
| ------------------------- | ----------------------------------------------------------- |
| 点了共享，**什么都不弹**             | 6.2 的扩展 Target 没建，或 `iosBroadcastExtension` 与 Product Name 不一致 |
| 选择器弹出来了，但里面**一片空白**       | 同上：`iosBroadcastExtension` 写错                                  |
| 控制中心列表里没有你的 App           | 6.6 的 Copy Files 没配                                         |
| 有图标，点了没反应 / 立刻结束          | 6.4 App Group 没勾全；或 6.5 依赖没装                                |
| 在录屏（顶部变红），但别人看不到          | App Group 三处不一致（6.1 第 6 步 / 6.4 / SampleHandler 的 APPGROUP） |
| 提示"集成错误（SDK 版本号不相符合）"      | 6.5 里扩展的 SDK 版本和主 App 不一致                                   |
| 别人共享我看不到                  | Dart 侧问题，不是扩展问题 —— 检查 `onUserSubStreamAvailable` 是否触发       |

---

## 7. 改包名 / 改 App Group 要同步的地方

包名（Bundle ID）改了要同步：

- `android/app/build.gradle(.kts)` 的 `namespace` / `applicationId`
- `app/platform/android/*.kt` 里的 `package` 行（或重跑 `apply.py`）
- Xcode 里 Runner 和 BroadcastExtension 两个 target 的 Bundle Identifier（扩展必须是主 App 的**子标识**）

App Group 涉及 **4 处** + 开发者后台：

1. `lib/core/app_config.dart` → `AppConfig.iosAppGroup`
2. `ios/Runner/Runner.entitlements`
3. `ios/BroadcastExtension/BroadcastExtension.entitlements`
4. `ios/BroadcastExtension/SampleHandler.swift` → `APPGROUP`

**好消息：这 4 处现在由脚本统一写，不需要手工同步。**

```bash
python platform/apply.py --no-create --org com.acme
```

App Group 默认按 `--org` 推导成 `group.com.acme.meetingApp`，脚本会把上面 4 处
（含 Dart 常量）**一次写成同一个字符串**，再跑几次也不会重复追加。

> 这条自动化的由来：之前 `apply.py` 只改 entitlements、不改 Dart 常量，于是很容易出现
> "脚本跑过了但 App Group 不一致" —— 现象恰好就是最难查的那种「在录屏但别人看不到」。
> 现在把最容易漏的一环交给脚本。

Apple 开发者后台那两个 App ID 的 App Groups 勾选仍然**只能手工做**（脚本碰不到后台）。

---

## 8. 常见问题

**Q: `flutter` 命令本身报 `CreateFile failed 231 / process_win.cc`？**  
这台机器上 Dart 无法创建带管道的子进程，`flutter` CLI 跑不起来。绕开办法是直接调 SDK：

```bash
FLUTTER_ROOT=D:/2026/flutter \
  "D:/2026/flutter/bin/cache/dart-sdk/bin/dart.exe" pub get
```

另外 `bin/cache/flutter.version.json` 是脚本按真实 git 信息补出来的（flutter 工具没跑起来所以没生成），  
不要删——删了 flutter CLI 会因为找不到版本文件去调 git，又撞上同样的管道问题。

**Q: 能进会议、能看到别人，但自己黑屏且没声音？**  
先查**权限**，再查 SDK —— 这个症状九成是权限。
Android 上没给相机/麦克风权限时，TRTC 返回的是 `-1314`（摄像头未授权）/ `-1317`（麦克风未授权），
但它**不会弹系统框**，所以没人会往权限方向想。
对照 `lib/core/permissions.dart` 确认 `AppPermissions.requestForMeeting()` 被调到。
iOS 上如果连弹窗都不出现，查 Podfile 里的 `PERMISSION_CAMERA` 宏（见第 3.1 节）。
如果只黑了你自己但听得到自己回声，则不是权限而是占用（`-1316` / `-1319`）。

**Q: 点了「共享屏幕」，按钮一直停在「等待确认…」？**  
说明系统那个确认弹窗没走完。这是**正常中间态**，不是卡死：
等最多 25 秒（安卓）/ 60 秒（iOS）会自动复位，并提示你重试。
安卓请确认在授权框上点了「开始录制」；iOS 要确认那个录屏选择器里列出了
「会议屏幕共享」并且点了「开始直播」。若选择器里是**空白**的，
说明扩展 Target 没建或 `AppConfig.iosBroadcastExtension` 名字不一致（见 6.7）。

**Q: 点共享时报「房间里已经有人在共享屏幕了」？**  
TRTC 的辅流同一时刻只允许一个人上行（错误码 `-102016`），后端也做了同样的抢占。
等对方停止后再试即可。

**Q: 点了「共享屏幕」，屏幕顶部变红但会议里谁都没看到画面（iOS）？**  
检查三处 App Group 是否一字不差（见 6.1 第 6 步 / 6.4 / SampleHandler 的 `APPGROUP`），
以及 `AppConfig.iosAppGroup`。扩展采集到了帧但主进程收不到，就是这个原因。
另外确认扩展的 `TXLiteAVSDK_Professional/ReplayKitExt` **没有写死版本号**。

**Q: 只有我一个人能看到自己，别人看到全黑？**  
先看 `MediaStateChanged` 有没有到（SignalR 负责业务状态），再看 `onUserVideoAvailable` 有没有到（TRTC 负责媒体状态）。  
两者要对同一个数字 `userId`。后端的 `userSig` 必须用**数字 userId** 签发，不能用昵称（中文昵称还会被 TRTC 直接拒绝）。

**Q: 有人开始共享后，别人之前共享的为什么停了？**  
这是**后端有意为之**的抢占逻辑：同一时刻只允许一个人共享，服务端会清掉其他人并广播  
`ShareStopped`。客户端收到后必须真的停掉自己的上行流，不能只改 UI 状态。

**Q: 重连后收不到任何消息了？**  
SignalR 重连是**新连接**，组关系会丢。代码在 `onreconnected` 里重新调了 `Rejoin(meetingId)`，  
如果你改动这块逻辑要保留这个行为。

---

## 9. 真机验证清单（交付验收用）

按顺序跑，**每项都要两个人（两台手机）**——一个人测不出音视频。

### 9.0 前置

1. 后端跑起来，两台手机和电脑在**同一个 WiFi**
2. 两台手机都装好 App，登录不同账号
3. **首次进会议时系统会弹「摄像头」「麦克风」权限框 → 两个都要点允许**

   > 这是最常见的一次性失败点。点成"拒绝"后不会再弹窗，表现就是
   > 「能进会议、能看到别人，自己却黑屏无声」，很容易误判成 SDK 有问题。
   > 补救：用提示里那个**「去设置」**按钮，或到系统设置里手动开。

4. 手机 A 建会议，手机 B 用会议号加入
5. 双方确认页面上方显示的是**电脑的局域网 IP**（不是 `127.0.0.1`）

### 9.1 视频（必测）

| 步骤                     | 预期                                    |
| ---------------------- | ------------------------------------- |
| A 进会议                  | A 能看到自己的画面（本地预览不等进房就应出现）              |
| B 进会议                  | A 能看到 B 的视频方块，B 也能看到 A 的             |
| A 点摄像头按钮关掉             | B 那边 A 的方块**立刻变成头像占位**，不是"卡住的最后一帧"     |
| A 再打开                  | B 那边画面恢复                              |
| A 点翻转摄像头               | A 自己的画面前后摄切换；失败时按钮状态不应错位              |
| A 把 App 切后台再切回          | 画面能恢复（不恢复说明摄像头被占用或没重新 `startLocalPreview`） |

### 9.2 语音（必测）

| 步骤                     | 预期                                        |
| ---------------------- | ----------------------------------------- |
| A 说话                   | B 能听到；A 的方块出现绿色说话边框                       |
| B 说话                   | A 能听到；B 的方块出现绿色边框（**这条最容易出问题**，见下）        |
| A 静音                   | B 那边 A 的方块麦克风图标变红，且听不到声音                  |
| 主持人长按 A 强制静音           | A 的麦克风**真的被关闭**（本地也收不到音），不只是 UI 变化        |
| 开外放 / 插耳机              | 音频路由跟着切换；视频通话默认必须是**外放**，不能是听筒（听筒声音极小）    |

> ⚠️ 说话高亮的坑：TRTC 的音量回调里，**本地用户的 `userId` 是空字符串**。
> 代码在 `RtcService._buildListener()` 的 `onUserVoiceVolume` 里用进房时记下的
> `_selfUserId` 把空串补了回来。如果你重构这块，"自己说话时自己高亮"会静默失效。

### 9.3 屏幕共享（必测，两端各测一遍）

> 两个平台都有一个共同点：**点完按钮不等于已经在共享**。
> 安卓要等用户在系统授权框上点「开始录制」，iOS 要等用户点「开始直播」。
> 所以在用户点确认之前，底部按钮显示的是 **等待确认…** 而不是「停止共享」——
> 这是刻意设计的中间态，用来说明"球已经踢给系统了"。
> 真正开始后会由 TRTC 的 `onScreenCaptureStarted` 回调把状态切成「停止共享」。

**Android 侧**

| 步骤                   | 预期                                                     |
| -------------------- | ------------------------------------------------------ |
| A 点「共享屏幕」            | 按钮变**等待确认…**；通知栏出现前台服务通知；系统弹「开始录制或投放？」   |
| 选**开始录制**             | 按钮变**停止共享**且变蓝；手机顶部出现投屏图标；B 那边出现 A 的共享画面       |
| A 切到别的 App（比如打开微信）   | B 那边能看到微信界面（**系统级共享的标志**）                             |
| A 停止共享               | B 那边共享画面消失，通知栏的前台服务通知也消失                              |
| **停止后 A 自己的摄像头画面**    | 应恢复成实时预览，**不能是黑框**（这条专门验 `_resumeCamera()` 有没有真的重启预览）   |
| A 在第 1 步选择「取消」       | 不崩，按钮复位成「共享」，摄像头恢复（走 `onError(-1308)` 分支）              |

**iOS 侧**（必须先做完第 6 节全部步骤）

| 步骤                        | 预期                                     |
| ------------------------- | -------------------------------------- |
| A 点「共享屏幕」                 | 按钮变**等待确认…**；**自动弹出**系统选择器（`RPSystemBroadcastPickerView`） |
| 选择器里                    | 有「会议屏幕共享」这一项，**不能是一片空白**              |
| 选中 → 开始直播                 | 按钮变**停止共享**；手机顶部变红；B 那边出现 A 的共享画面     |
| A 切到别的 App                | B 能看到（**系统级共享的标志**）                    |
| A 停止共享                    | B 那边共享画面消失；摄像头预览恢复                    |
| 第 1 步直接把选择器**划掉**        | 60 秒内按钮自动复位成「共享」并提示；**不能永远卡在"等待确认…"** |

### 9.4 共享的抢占行为

| 步骤              | 预期                                                     |
| --------------- | ------------------------------------------------------ |
| A 正在共享，B 也点共享   | B 顶掉 A；A 的共享**真的停了**（本地上行流也断），A 收到提示                   |

> 这是后端有意的抢占逻辑（同一时刻只允许一人共享，服务端清掉其他人并广播
> `ShareStopped`）。客户端收到必须**真停上行流**，只改 UI 会继续占着辅流，导致 B 也共享不了。

### 9.5 断网重连

| 步骤              | 预期                                    |
| --------------- | ------------------------------------- |
| A 开飞行模式 10 秒再关 | A 自动重连；重连后**仍能收到聊天消息**（说明 `Rejoin` 生效） |
| 重连后            | 视频画面自行恢复，不需要退出重进会议                    |

---

## 10. 已知事项与设计取舍

- **已从 `tencent_trtc_cloud 3.1.4` 迁移到官方的 `tencent_rtc_sdk 13.5.2`。**
  旧包在 pub.dev 上已标记 discontinued。新包的收益很实在：
  - 事件回调是**强类型命名回调**（`TRTCCloudListener(onEnterRoom: (result) {...})`），
    编译期就能发现参数写错；旧包是"枚举 + `dynamic params`"，`onEnterRoom` 传裸 `int`、
    `onRemoteUserEnterRoom` 传裸 `String`、其余传 `Map`，只能在运行时猜。
  - 所有 `streamType` 从 `int` 常量变成枚举 `TRTCVideoStreamType`，不再可能传错值。
  - iOS 的屏幕共享有**专用接口** `startScreenCaptureByReplaykit(...)`，
    比旧包"靠传不传 appGroup 来决定内部路由"明确得多。
  - 旧包把"停止录屏"的回调拼错成 `onScreenCaptureStoped`（少一个 p），
    新包已修正为 `onScreenCaptureStopped`。
- 迁移范围**收敛在 4 个文件**（`rtc_service.dart` + 三个引用点），业务逻辑零改动——
  因为 TRTC 被 `RtcService` / `RtcEventListener` 两个接口隔离住了。
- `TRTCCloudVideoView` 在新包里**只接受 `key` 和 `onViewCreated`**，
  不再接受 `hitTestBehavior`（它内部固定为 `transparent`）。
- `tencent_rtc_sdk` 的 Android 实现包名是 `com.tencent.trtcplugin`（旧包是 `com.tencent.trtccloud`），
  并且新增了 `super_player`（`com.tencent.vod.flutter`）作为原生 SDK 承载者，
  两者都已加进 `proguard-rules.pro`。
- **新 SDK 依然不自带录屏前台服务**（已逐文件搜过插件源码），所以
  `ScreenShareService.kt` 仍然是 Android 屏幕共享的生死线。
- 后端 `RtcController.GetUserSig()` 之前用昵称当 TRTC userId 签发签名，会导致进房被拒
  （中文昵称还会被 TRTC 直接拒绝）。已改为取 `ClaimTypes.NameIdentifier`。

  > 顺带更正一处错误码：以前这里写的是"报 `-3317`"，但官方错误码表里
  > `-3317 = ERR_TRTC_INVALID_SDK_APPID`（sdkAppId 错），
  > **签名校验失败是 `-100018`（ERR_TRTC_USER_SIG_CHECK_FAILED）**，
  > `-3320` 是 userSig 参数为空。之前那个说法会把排查方向从签名带偏到 AppId 上。
