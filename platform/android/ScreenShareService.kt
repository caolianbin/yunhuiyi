//  ⚠️ 包名占位：platform/apply.py 会按 build.gradle 里的 namespace
//     自动替换本行，并把文件放到 android/app/src/main/kotlin/<包路径>/ 下。
//     手工放置时请同步改成你自己的包名。
package __ANDROID_PACKAGE__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 屏幕共享前台服务（Android 专用，iOS 不需要 —— iOS 靠 ReplayKit 扩展）。
 *
 * ──────────── 为什么非要有这个东西 ────────────
 * Android 10（API 29）起，MediaProjection 必须运行在
 * `foregroundServiceType="mediaProjection"` 的前台服务里。
 * 如果只是直接调 TRTC 的 startScreenCapture，会在系统授权回调那一刻直接崩：
 *
 *   java.lang.SecurityException: Media projections require a foreground
 *   service of type ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
 *     at android.media.projection.MediaProjection.<init>(MediaProjection.java:58)
 *     at com.tencent.rtmp.video.TXScreenCapture$TXScreenCaptureAssistantActivity
 *        .onActivityResult(TXScreenCapture.java:45)
 *
 * 这是腾讯云 TRTC Android SDK 的已知行为：**SDK 不会自己起前台服务**，
 * 必须由宿主 App 提前起好。所以这个类是必须的，不是可选优化。
 *
 * ──────────── 正确调用顺序 ────────────
 *   1. Dart 侧先通过 MethodChannel 调 startScreenShareService()
 *      → 本服务 startForeground()，进入前台
 *   2. 再调 TRTC 的 startScreenCapture(...)
 *      → 系统弹「开始录制或投放？」授权框，用户同意后才真正开始采集
 *   3. 停止共享后调 stopScreenShareService()
 *      → 通知栏的「正在共享屏幕」消失
 *
 * 顺序反了（先 startScreenCapture 再起服务）同样会崩。
 */
class ScreenShareService : Service() {

    companion object {
        private const val CHANNEL_ID = "meeting_screen_share"
        private const val CHANNEL_NAME = "屏幕共享"
        private const val CHANNEL_DESC = "会议期间共享屏幕时保持采集不被系统中断"
        private const val NOTIFICATION_ID = 0x5C0E01

        /** Dart 侧调用：拉起前台服务。内部已按版本选择 startForegroundService。 */
        fun start(context: Context) {
            val intent = Intent(context, ScreenShareService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenShareService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        promoteToForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        promoteToForeground()
        // 录屏已经结束了，被系统杀掉后重启一个空服务没有任何意义。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // 传 true 连带清掉通知，否则通知栏会残留一条「正在共享屏幕」。
        stopForeground(true)
        super.onDestroy()
    }

    private fun promoteToForeground() {
        createChannelIfNeeded()

        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ 必须显式把服务类型声明成 mediaProjection，
            // 只写 Manifest 不够 —— 这里传错类型依然会抛 SecurityException。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            // LOW：不发声不震动。用 DEFAULT/HIGH 会让每次共享屏幕都弹一下提示音，很吵。
            NotificationManager.IMPORTANCE_LOW
        )
        channel.description = CHANNEL_DESC
        channel.setShowBadge(false)
        nm.createNotificationChannel(channel)
    }

    /**
     * 刻意不用 androidx 的 NotificationCompat：
     * Flutter 默认生成的 Android 工程并不保证带上 androidx.core 依赖，
     * 用框架自带的 Notification.Builder 可以零依赖跑通。
     */
    private fun buildNotification(): Notification {
        val tapIntent = Intent(this, ScreenShareService::class.java)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getService(this, 0, tapIntent, flags)

        // 复用 App 自己的图标，避免再往工程里塞 drawable 资源。
        // 注：通知栏小图标在系统里会被渲染成纯白剪影，这是 Android 的设计，不是 bug。
        val smallIcon = applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_menu_share

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("正在共享屏幕")
            .setContentText("会议正在进行中，点击返回会议")
            .setSmallIcon(smallIcon)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }
}
