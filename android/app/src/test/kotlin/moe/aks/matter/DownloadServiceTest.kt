package moe.aks.matter

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], application = Application::class, manifest = Config.NONE)
class DownloadServiceTest {
    private fun command(
        action: String,
        id: Int,
    ) = Intent().setAction(action).putExtra("id", id)

    @Test
    fun retainsOtherTransfersUntilTheLastDownloadFinishes() {
        val controller = Robolectric.buildService(DownloadService::class.java).create()
        val service = controller.get()
        val manager = shadowOf(service.getSystemService(NotificationManager::class.java))
        service.onStartCommand(command("start", 101).putExtra("filename", "a.md"), 0, 1)
        service.onStartCommand(command("start", 102).putExtra("filename", "b.pdf"), 0, 2)
        assertEquals(2, manager.size())
        assertTrue(manager.getNotification(101).flags and Notification.FLAG_ONGOING_EVENT != 0)
        service.onStartCommand(command("finish", 101).putExtra("status", "complete"), 0, 3)
        assertFalse(shadowOf(service).isStoppedBySelf)
        assertEquals("下载完成", manager.getNotification(101).extras.getString(Notification.EXTRA_TEXT))
        assertTrue(manager.getNotification(102).flags and Notification.FLAG_ONGOING_EVENT != 0)
        service.onStartCommand(command("finish", 102).putExtra("status", "cancelled"), 0, 4)
        assertTrue(shadowOf(service).isStoppedBySelf)
        assertNull(manager.getNotification(102))
        controller.destroy()
    }

    @Test
    fun reportsProgressAndOpensTheVerifiedUpdateFromCompletion() {
        val controller = Robolectric.buildService(DownloadService::class.java).create()
        val service = controller.get()
        val manager = shadowOf(service.getSystemService(NotificationManager::class.java))
        service.onStartCommand(command("start", 103).putExtra("filename", "Matter 更新"), 0, 1)
        service.onStartCommand(command("progress", 103).putExtra("received", 5L).putExtra("total", 10L), 0, 2)
        assertEquals(50, manager.getNotification(103).extras.getInt(Notification.EXTRA_PROGRESS))
        service.onStartCommand(
            command("finish", 103)
                .putExtra("status", "complete")
                .putExtra("installPath", "/cache/updates/matter.apk"),
            0,
            3,
        )
        val completed = manager.getNotification(103)
        assertEquals(0, completed.flags and Notification.FLAG_ONGOING_EVENT)
        val intent = shadowOf(completed.contentIntent).savedIntent
        assertEquals(DownloadService.ACTION_INSTALL_UPDATE, intent.action)
        assertEquals("/cache/updates/matter.apk", intent.getStringExtra("path"))
        val filesAction = completed.actions.single()
        assertEquals("在下载中查看", filesAction.title.toString())
        val filesIntent = shadowOf(filesAction.actionIntent).savedIntent
        assertEquals(DownloadService.ACTION_SHOW_UPDATE_FILE, filesIntent.action)
        assertEquals("/cache/updates/matter.apk", filesIntent.getStringExtra("path"))
        controller.destroy()
    }

    @Test
    fun failedDownloadsLeaveANonOngoingErrorNotification() {
        val controller = Robolectric.buildService(DownloadService::class.java).create()
        val service = controller.get()
        val manager = shadowOf(service.getSystemService(NotificationManager::class.java))
        service.onStartCommand(command("start", 104), 0, 1)
        service.onStartCommand(command("finish", 104).putExtra("status", "failed").putExtra("error", "断网"), 0, 2)
        val failed = manager.getNotification(104)
        assertEquals("下载失败：断网", failed.extras.getString(Notification.EXTRA_TEXT))
        assertEquals(0, failed.flags and Notification.FLAG_ONGOING_EVENT)
        assertTrue(shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }
}
