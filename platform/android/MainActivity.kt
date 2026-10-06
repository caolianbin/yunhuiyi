//  ⚠️ 包名占位：platform/apply.py 会自动替换本行并放到正确目录。
package __ANDROID_PACKAGE__

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 主 Activity。
 *
 * 唯一职责：给 Dart 侧开一条 MethodChannel，用来在开始/结束屏幕共享前后
 * 拉起和关闭 ScreenShareService（前台服务）。
 *
 * 通道名 "meeting_app/platform" 必须与
 * app/lib/core/platform_channel.dart 里的常量一致。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "meeting_app/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // 开始屏幕共享前必须先调这个。
                    // 不调会崩：Media projections require a foreground service ...
                    "startScreenShareService" -> {
                        try {
                            ScreenShareService.start(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("START_SERVICE_FAILED", e.message, null)
                        }
                    }

                    // 停止共享后调，清掉通知栏的「正在共享屏幕」。
                    "stopScreenShareService" -> {
                        try {
                            ScreenShareService.stop(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("STOP_SERVICE_FAILED", e.message, null)
                        }
                    }

                    // 用户拒绝权限后，引导去系统设置页手动开。
                    "openAppSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_SETTINGS_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
