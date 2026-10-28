package moe.aks.matter

import android.app.Application
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import java.io.File

@Implements(FileProvider::class)
class ShadowUpdateFileProvider {
    companion object {
        @JvmStatic
        @Implementation
        fun getUriForFile(
            context: Context,
            authority: String,
            file: File,
        ): Uri = Uri.parse("content://$authority/updates/${file.name}")
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(
    sdk = [33],
    application = Application::class,
    manifest = Config.NONE,
    shadows = [ShadowUpdateFileProvider::class],
    instrumentedPackages = ["androidx.core.content"],
)
class UpdateInstallerTest {
    private fun apk(): File {
        val context = RuntimeEnvironment.getApplication()
        val directory = File(context.cacheDir, "updates").apply { mkdirs() }
        return File(directory, "matter.apk").apply { writeBytes(byteArrayOf(1, 2, 3)) }
    }

    @Test
    fun opensTheSystemInstallerWithoutRedirectingToSourcePermissionSettings() {
        val context = RuntimeEnvironment.getApplication()
        assertFalse(context.packageManager.canRequestPackageInstalls())
        UpdateInstaller.install(context, apk().path)
        val started = shadowOf(context).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, started.action)
        assertEquals("application/vnd.android.package-archive", started.type)
        assertEquals("content", started.data?.scheme)
        assertTrue(started.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun rejectsFilesOutsideTheUpdateCache() {
        val context = RuntimeEnvironment.getApplication()
        val privateFile = File(context.cacheDir, "private.apk").apply { writeText("private") }
        assertThrows(IllegalArgumentException::class.java) { UpdateInstaller.install(context, privateFile.path) }
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun rejectsUnfinishedDownloads() {
        val context = RuntimeEnvironment.getApplication()
        val unfinished = File(apk().parentFile, "matter.apk.download").apply { writeText("partial") }
        assertThrows(IllegalArgumentException::class.java) { UpdateInstaller.install(context, unfinished.path) }
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun opensTheDownloadsUiWithoutLaunchingAnotherInstallRequest() {
        val context = RuntimeEnvironment.getApplication()
        UpdateInstaller.openDownloads(context)
        val started = shadowOf(context).nextStartedActivity
        assertEquals(DownloadManager.ACTION_VIEW_DOWNLOADS, started.action)
        assertTrue(started.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertNull(started.data)
    }
}
