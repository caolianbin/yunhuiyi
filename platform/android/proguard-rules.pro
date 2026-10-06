# ============================================================================
#  TRTC 混淆规则（Android）
#
#  用途：release 包里开启 R8/ProGuard 后，TRTC 依赖反射查找回调方法，
#        不保留这些类会出现「debug 正常、release 一进房就崩」
#        或「本地画面正常、远端画面全黑且无任何报错」这类极难排查的问题。
#
#  已由 platform/apply.py 自动挂到 build.gradle 的 release 构建类型上。
# ============================================================================

# ---- 腾讯云 TRTC 主体 ----
-keep class com.tencent.trtc.** { *; }
-keep class com.tencent.rtmp.** { *; }
-keep class com.tencent.liteav.** { *; }
-keep class com.tencent.rtc.** { *; }

# 音视频处理 / 美颜 / 设备管理
-keep class com.tencent.ugc.** { *; }
-keep class com.tencent.beauty.** { *; }

# ---- TRTC 通过反射回调的监听接口，不能裁剪 ----
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepclassmembers class * implements com.tencent.trtc.TRTCCloudListener {
    <methods>;
}

# ---- Flutter 插件注册表（Flutter 靠反射找插件入口，被裁掉会直接白屏） ----
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# ---- 本项目实际使用的插件包 ----
# tencent_rtc_sdk 的 Android 实现（旧包是 com.tencent.trtccloud，已废弃）
-keep class com.tencent.trtcplugin.** { *; }
# super_player 的 Android 实现（tencent_rtc_sdk 的原生 SDK 由它承载）
-keep class com.tencent.vod.flutter.** { *; }

# ---- Gson / 序列化（TRTC 内部用） ----
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# ---- 签名错误的排查线索：保留 native 崩溃堆栈行号 ----
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
