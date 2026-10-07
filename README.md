# 会议 App（Flutter · Android + iOS）

会议系统的移动端。支持**多人音视频、语音、系统级屏幕共享**。

> 完整的前端重构说明：本项目的前端已从 uni-app 重写为 Flutter，
> 原因是 **iOS 的系统级屏幕共享**（能录到整个屏幕，不只本应用画面）
> 必须往 iOS 工程里加 Broadcast Upload Extension Target，
> 而 HBuilderX 云打包做不到这件事。
> 平台配置与打包操作见 **[platform/README.md](platform/README.md)**。

---

## 快速开始

```bash
cd app

# 1. 生成 android/ 与 ios/ 目录
flutter create --platforms=android,ios --org com.example --project-name meeting_app .

# 2. 打平台补丁（权限 / 前台服务 / 隐私描述 / 混淆 / App Group）
python platform/apply.py --no-create

# 3. 依赖
flutter pub get

# 4. 跑（iOS 必须先完成 platform/README.md 第 6 节，且必须真机）
flutter run
```

**改后端地址不用重新打包**：登录页右上角的「服务器设置」可运行时修改并持久化。
默认值在 `lib/core/app_config.dart`。

---

## 用 Codemagic 出包（CI）

仓库根目录的 `codemagic.yaml` 里有**三个** workflow，按需要选：

| Workflow          | 要 Apple 账号 | 产物            |
| ----------------- | --------- | ------------- |
| `android-release` | 否         | Android APK   |
| `ios-build-check` | **否**     | 无（只编译，不签名）    |
| `ios-release`     | **是**     | iOS IPA       |

关于 iOS 为什么拆成两个：出包失败分"工程/代码问题"和"签名/账号问题"两类，
后者会把前者完全遮住。`ios-build-check` 不需要任何证书，能把第一类单独暴露出来，
先用它跑绿再去配签名，能省掉大量来回。

`android-release` 有两条约束，踩中了都会以**看起来完全无关**的错误收场：

**1. `lib/main.dart` 这个文件名不能改。**
`flutter build` / `flutter run` 在不传 `--target` 时默认就找它。入口若只存在于
`lib/app.dart`，得到的报错是 `Target file "lib/main.dart" not found` ——
而 Codemagic 的 Flutter 向导模板、IDE 的运行按钮，找的都是 `lib/main.dart`。
所以：`main.dart` 只做 bootstrap（绑定 binding → `Session.load()` → `runApp`），
Widget 树继续留在 `app.dart`。

**2. 必须让 Codemagic 真的去读 `codemagic.yaml`。**
用 UI 里那套 Workflow Editor 的话，仓库里的 yaml 会被**完全忽略**。
判断方法很简单：构建日志里出现「生成 Android 平台工程」这类中文步骤名 = yaml 生效；
只有 `flutter pub get` / `flutter build` 两条 = 还在用 UI 配置。
切换方式：Settings → Build configuration → 选 `codemagic.yaml`，
再在 Start new build 时选 `android-release`。

**3. 依赖的 `compileSdk` 不能超过 Flutter 自己的默认值（当前 36）。**
一旦有依赖把 compileSdk 抬到 37，构建会报出一句既没有包名、也没有版本线索的话：

```
Could not find target with hash string 'android-37'
```

原因是 CI 的 Android SDK 仓库对 API 37 只提供「次要版本」包（安装到
`platforms/android-37.0`），而 Gradle 是按 `android-37` 去找平台的，两边对不上。

目前已知的**唯一**触发点是 `permission_handler`：13.x 依赖
`permission_handler_android` 14.x，后者写死 `compileSdk = 37`，且源码里用了
API 37 才有的 `Manifest.permission.ACCESS_LOCAL_NETWORK` —— 它出现在 switch 的
`case` 标签上，而 case 标签必须是编译期常量，所以**没法**靠降编译版本绕开。
pubspec 里已钉在 `^12.0.0`（配 `permission_handler_android` 13.0.1，compileSdk 35），
Dart 侧 API 与 13.x 完全一致 —— **不要升**，原因都写在 pubspec 的注释里。

CI 里有一道 `platform/precheck_android_sdk.py` 专门把这类问题翻译成人话
（只提醒、不中断构建；万一以后 SDK 仓库能正常提供该平台，它也不会误伤）。
本地也能跑：`python3 platform/precheck_android_sdk.py`。

CI 里为什么还要跑 `flutter create`：`android/` 与 `ios/` 都**没有入库** ——
它们含二进制（`gradle-wrapper.jar` / `Runner.xcodeproj` 的产物），
没法用源码方式维护。在任意一台能跑 flutter 的机器上执行一次
`flutter create --platforms=android,ios --org <你的org> .` 并把两个目录提交进仓库，
就可以把那一步从 yaml 里删掉，后续构建更快也更可控。

> **iOS 的工作流已经补齐**（`ios-build-check` / `ios-release`），
> 包括此前被认为"物理上只能人工在 Xcode 里点"的 Broadcast Upload Extension
> Target —— 现在由 `platform/ios/add_broadcast_extension.py` 直接写进
> `project.pbxproj`，纯 CI 环境也能建出来。
>
> 但**代码签名仍然只能人工**：App Group 需要付费 Apple 账号，后台勾选脚本碰不到。
> 完整步骤（含签名与 Codemagic 配置）见 [platform/README.md](platform/README.md) 第 6 节。

---

## 代码结构

```
lib/
├── main.dart                   构建入口（文件名不可改）：binding → Session.load() → runApp
├── app.dart                    Widget 树入口：MultiProvider + 登录态路由
├── core/
│   ├── app_config.dart         全局常量（后端地址、Hub 路径、App Group、录屏扩展名、共享编码参数）
│   ├── session.dart            登录态（token / 用户 / baseUrl），SharedPreferences 持久化
│   ├── api_client.dart         Dio 封装，统一 ApiException + 可操作的网络错误提示
│   ├── app_theme.dart          主题
│   ├── permissions.dart        运行时权限（相机/麦克风/通知）—— **不申请就会黑屏无声**
│   └── platform_channel.dart   MethodChannel：控制 Android 屏幕共享前台服务
├── models/models.dart          后端 DTO 映射（防御性解析，字段增删不崩）
├── services/
│   ├── auth_service.dart       注册 / 登录 / 资料 / 头像
│   ├── meeting_service.dart    会议 CRUD / 加入 / 文件上传 / TRTC 签名
│   ├── signalr_service.dart    SignalR 实时（20 个事件回调 + 重连重新入组）
│   └── rtc_service.dart        TRTC 音视频与屏幕共享（**唯一与 TRTC 强耦合的文件**）
├── state/
│   └── room_controller.dart    会议页大脑
└── pages/
    ├── login / register / home / create_meeting / join_meeting
    ├── meeting_detail / profile
    └── room/
        ├── room_page.dart          布局（共享舞台 / 视频宫格 / 等候室）
        └── widgets/                video_tile / control_bar / panels（聊天·成员·更多）

packages/
└── replay_kit_launcher/        iOS 系统级屏幕共享的「触发按钮」（本地 fork，原因见其 README）

platform/                       平台工程生成与打补丁（详见其 README.md）
├── apply.py                    一键打 Android/iOS 配置补丁（含自动补 ios/Podfile）
├── precheck_android_sdk.py     把 compileSdk 平台缺失翻译成人话
├── android/                    ScreenShareService.kt 等注入 android/ 的源码
└── ios/
    ├── BroadcastExtension/     录屏扩展源码（SampleHandler.swift 等 3 个文件）
    └── add_broadcast_extension.py
                                  往 Runner.xcodeproj 里写进扩展 Target（纯标准库）
```

### 屏幕共享的"开始"为什么不是点了就算

这是本工程最容易被误判成 bug 的地方，单独写清楚。

`startScreenCapture()` 返回的是一个「需要用户去点什么」的枚举，**而不是**"已在共享"：

| 平台 | 点完按钮之后 |
|---|---|
| Android | 系统弹 `MediaProjection` 授权框「开始录制或投放？」→ 用户点**开始录制** |
| iOS | 弹出系统 `RPSystemBroadcastPickerView` → 用户点**开始直播** |

iOS 还多一层限制：**系统不允许 App 自己启动系统级录屏**（iOS 11 起），
而 `startScreenCaptureByReplaykit(...)` 只是让 SDK 进入"等待共享数据"状态，
**它不弹任何界面** —— 没有那个触发入口，用户点完共享就是"什么也没发生、日志也没有错"。

所以状态由 TRTC 的 `onScreenCaptureStarted` 回调来驱动，代码里体现为三态：

```
点「共享」→ sharePending = true   （按钮显示"等待确认…"）
        ├─ onScreenCaptureStarted  → isSharing = true（按钮变"停止共享"，此时才上报服务端）
        ├─ onError(-1308) / 用户取消 → 复位成"共享"，并恢复摄像头
        └─ iOS 60 秒无回调（用户把选择器划掉不会有任何回调）→ 超时复位
```

**如果在这里图省事直接 `isSharing = true`**：用户一点「取消」，按钮就会永远停在
"停止共享"，服务端也一直认为你在共享，别人会一直等你的画面。

另一个相关的真 bug 已修：开共享时会 `stopLocalPreview()` 关摄像头，
而结束共享时**只把 `cameraOn` 这个状态位改回 true 是不够的**，
必须真的重新 `startLocalPreview`（见 `RoomController._resumeCamera()`），
否则按钮显示"视频已开"、状态也上报成开，但自己的画面一直是黑的。

### 为什么 `room_controller.dart` 是核心

会议里有两套**互相独立**的状态源，必须按同一个 `userId` 对齐：

| 状态源 | 负责 |
|---|---|
| **SignalR** | 业务状态：谁在会里、谁举手、谁被静音、谁在共享、聊天、投票、管控指令 |
| **TRTC** | 媒体状态：谁的视频流可用、谁的辅流（屏幕）可用、谁在说话、音量 |

举例：服务端说"王某正在共享"（业务），但真正的画面要等 TRTC 的
`onUserSubStreamAvailable` 到了才能播。两者都由 `RoomController` 收敛后再交给 UI。

另外两类必须"真做"而不能只改 UI 的操作：

- 主持人硬静音我 → 必须真的 `muteLocalAudio(true)`
- 我的共享被抢占（后端只允许一人共享）→ 必须真的停上行流

### 权限是"能视频能语音"的前置条件

`RoomController.start()` 一进来就调 `AppPermissions.requestForMeeting()` 申请
相机 + 麦克风，申请结果决定本地摄像头/麦克风是否打开：

- **Android**：这两个是危险权限，只声明不够，必须运行时申请。
  不申请时 TRTC 回 `-1314`（摄像头未授权）/ `-1317`（麦克风未授权），**且不弹任何系统框**——
  现象是「能进会议、能看到别人，自己却黑屏无声」，很容易误判成 SDK 问题。
- **iOS**：`permission_handler` 的权限由 Podfile 里的 `PERMISSION_*` 宏守卫，
  不配宏则 `Permission.camera.request()` 静默失效（永远 denied）。
  这一步由 `platform/apply.py` 自动注入。

**权限被拒也照常进会议**——仍然能看别人、听别人，只是本地音视频关闭，
并弹一条带「去设置」按钮的提示（否则用户误点一次拒绝就只能卸载重装）。

---

## 后端对接

| 项 | 值 |
|---|---|
| REST 前缀 | `/api` |
| SignalR Hub | `/hubs/meeting`（JWT 走 `?access_token=` 查询参数） |
| 默认端口 | `5000` |
| TRTC | `SdkAppId` / `SecretKey` 已在后端 `appsettings.json` 配好，客户端登录后取签名 |

TRTC 的 `userId` 就是后端的**数字用户 ID** ——
`userSig` 必须用同一个 ID 签发，否则进房会以 userSig 校验失败被拒
（错误码 `-100018`，注意**不是** `-3317`，后者是 sdkAppId 错误）。
（后端 `RtcController.GetUserSig()` 已修正为取
`ClaimTypes.NameIdentifier` 而不是昵称；中文昵称还会被 TRTC 直接拒绝。）

---

## 已知事项

- **TRTC 已从 `tencent_trtc_cloud 3.1.4` 迁移到官方在维护的 `tencent_rtc_sdk 13.5.2`。**
  旧包已被 pub.dev 标记 discontinued。新包的收益：
  - 事件回调是**强类型命名回调**（`TRTCCloudListener(onEnterRoom: (result) {...})`），
    写错参数编译期就报错；旧包是"枚举 + `dynamic params`"，只能在运行时猜参数形态。
  - 所有 `streamType` 从 `int` 常量变成枚举 `TRTCVideoStreamType`。
  - iOS 屏幕共享有**专用接口** `startScreenCaptureByReplaykit(streamType, encParam, appGroup)`。
  - 旧包把"停止录屏"回调拼错成 `onScreenCaptureStoped`（少一个 p），新包已修正。
  - 迁移范围只有 4 个文件（`rtc_service.dart` + 3 个引用点），业务逻辑零改动——
    因为 TRTC 被 `RtcService` / `RtcEventListener` 接口隔离住了。
- **iOS 屏幕共享多了一个本地插件 `packages/replay_kit_launcher/`。**
  原因见上面「屏幕共享的"开始"为什么不是点了就算」一节：
  iOS 不允许 App 自己启动系统级录屏，必须由用户触发，
  而 pub.dev 上的同名包不支持 Dart 3，所以 fork 了一份（改动与许可见该目录 README）。
- **顺带修掉的一个真 bug**：结束屏幕共享时只把 `cameraOn` 状态改回 true、
  却没真的重新 `startLocalPreview`，导致"按钮显示视频已开、自己画面全黑"。
  现在统一走 `RoomController._resumeCamera()`。
- **App Group 不再需要手工同步**：`apply.py` 会把 `--org` 推导出的
  App Group 一次性写进 Dart 常量 / 两份 entitlements / SampleHandler，
  避免"脚本改了 entitlements 却漏改 Dart 常量"（那正是最难查的
  「在录屏但别人看不到」）。开发者后台的 App Groups 勾选仍需手工做。
- **未在真机验证过音视频与屏幕共享** —— 开发机上 `flutter` CLI 不可用
  （Dart 运行时无法创建带管道的子进程），只做到了静态分析零错误零警告
  （含 lint 规则，且已用故意写错的探针验证过分析器确实能发现问题）。
  **首次真机联调请按 `platform/README.md` 第 9 节的验证清单逐项确认**——
  视频 / 语音 / 屏幕共享三块，每块都要两台手机对着测。
  其中屏幕共享要特别确认两条**只在真机上才暴露**的项：
  ① 授权/开始后在对方那边真的能看到画面；
  ② 停止共享后自己的摄像头画面恢复成实时预览而不是黑框。
- **CI 出的 release APK 目前是 debug 签名。** 仓库里虽有 `upload-keystore.jks`，
  但没有 `android/key.properties`，`build.gradle` 里也没配 `signingConfig`，
  于是 Gradle 回退到 debug 签名（构建日志里会有一行 warning）。
  侧载安装没问题，但**不能上架**，且换签名后无法覆盖安装。
  顺带一提：签名文件本身已经提交进仓库了，建议改成用 Codemagic 的
  加密环境变量 / 安全文件注入，并从仓库移除。
