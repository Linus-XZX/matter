package moe.aks.matter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager

/** The transfers stay in the Matrix/Dart clients; this service owns their OS lifetime. */
class DownloadService : Service() {
    private data class Transfer(
        val filename: String,
        var notification: Notification,
    )

    private val active = linkedMapOf<Int, Transfer>()
    private lateinit var notifications: NotificationManager
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, "文件下载", NotificationManager.IMPORTANCE_LOW),
        )
        wakeLock =
            getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:downloads")
                .apply { acquire(6 * 60 * 60 * 1000L) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val id = intent?.getIntExtra("id", -1) ?: -1
        if (id == -1) {
            if (active.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            "start" -> {
                val filename = intent.getStringExtra("filename") ?: "文件"
                val notification = buildNotification(id, filename, "正在下载…", ongoing = true)
                active[id] = Transfer(filename, notification)
                keepForeground()
                notifications.notify(id, notification)
            }

            "progress" -> {
                active[id]?.let { transfer ->
                    val received = intent.getLongExtra("received", 0)
                    val total = intent.getLongExtra("total", 0)
                    val percent = if (total > 0) (received * 100 / total).coerceIn(0, 100).toInt() else null
                    transfer.notification =
                        buildNotification(
                            id,
                            transfer.filename,
                            if (percent == null) "正在下载…" else "正在下载 $percent%",
                            ongoing = true,
                            percent = percent,
                        )
                    notifications.notify(id, transfer.notification)
                }
            }

            "finish" -> {
                active.remove(id)?.let { transfer ->
                    if (active.isEmpty()) {
                        stopForeground(STOP_FOREGROUND_DETACH)
                    } else {
                        keepForeground()
                    }
                    val status = intent.getStringExtra("status")
                    if (status == "cancelled") {
                        notifications.cancel(id)
                    } else {
                        val installPath = if (status == "complete") intent.getStringExtra("installPath") else null
                        val text =
                            if (status == "complete") {
                                if (installPath == null) "下载完成" else "下载完成，点击安装更新"
                            } else {
                                "下载失败：${intent.getStringExtra("error") ?: "请重试"}"
                            }
                        notifications.notify(
                            id,
                            buildNotification(id, transfer.filename, text, installPath = installPath),
                        )
                    }
                    if (active.isEmpty()) stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun keepForeground() {
        val (id, transfer) = active.entries.first()
        startForeground(id, transfer.notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    private fun buildNotification(
        id: Int,
        filename: String,
        text: String,
        ongoing: Boolean = false,
        percent: Int? = null,
        installPath: String? = null,
    ): Notification {
        val open =
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (installPath != null) {
                    action = ACTION_INSTALL_UPDATE
                    putExtra("path", installPath)
                }
            }
        return Notification
            .Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(filename)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    id,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            ).apply {
                if (ongoing) setProgress(100, percent ?: 0, percent == null)
            }.build()
    }

    override fun onTimeout(
        startId: Int,
        fgsType: Int,
    ) {
        for ((id, transfer) in active) {
            notifications.notify(id, buildNotification(id, transfer.filename, "下载超时，请重试"))
        }
        active.clear()
        stopForeground(STOP_FOREGROUND_DETACH)
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "matter_downloads"
        const val ACTION_INSTALL_UPDATE = "moe.aks.matter.INSTALL_UPDATE"
    }
}
