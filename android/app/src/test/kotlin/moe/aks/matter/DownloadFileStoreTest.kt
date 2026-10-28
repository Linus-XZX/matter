package moe.aks.matter

import android.app.Application
import android.content.ContentProvider
import android.content.ContentUris
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import java.io.File
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], application = Application::class, manifest = Config.NONE)
class DownloadFileStoreTest {
    private class DownloadsProvider : ContentProvider() {
        val rows = mutableMapOf<Uri, ContentValues>()
        val files = mutableMapOf<Uri, File>()
        var failWrite = false

        override fun onCreate() = true

        override fun getType(uri: Uri) = "application/octet-stream"

        override fun query(
            uri: Uri,
            projection: Array<out String>?,
            selection: String?,
            args: Array<out String>?,
            order: String?,
        ): Cursor? = null

        override fun insert(
            uri: Uri,
            values: ContentValues?,
        ): Uri {
            val destination = ContentUris.withAppendedId(uri, (rows.size + 1).toLong())
            rows[destination] = ContentValues(values)
            files[destination] = File.createTempFile("saved", ".bin", context!!.cacheDir)
            return destination
        }

        override fun openFile(
            uri: Uri,
            mode: String,
        ): ParcelFileDescriptor {
            if (failWrite) throw IOException("disk full")
            return ParcelFileDescriptor.open(files.getValue(uri), ParcelFileDescriptor.MODE_READ_WRITE)
        }

        override fun update(
            uri: Uri,
            values: ContentValues?,
            selection: String?,
            args: Array<out String>?,
        ): Int {
            rows.getValue(uri).putAll(values)
            return 1
        }

        override fun delete(
            uri: Uri,
            selection: String?,
            args: Array<out String>?,
        ): Int {
            rows.remove(uri)
            files.remove(uri)?.delete()
            return 1
        }
    }

    private fun provider(): DownloadsProvider {
        val context = RuntimeEnvironment.getApplication()
        return DownloadsProvider().apply {
            attachInfo(context, ProviderInfo().apply { authority = "media" })
            ShadowContentResolver.registerProviderInternal("media", this)
        }
    }

    private fun source(): File {
        val context = RuntimeEnvironment.getApplication()
        val staging = File(context.cacheDir, "matter_downloads/test").apply { mkdirs() }
        return File(staging, "report.pdf").apply { writeBytes(byteArrayOf(1, 2, 3)) }
    }

    private fun update(): File {
        val context = RuntimeEnvironment.getApplication()
        val directory = File(context.cacheDir, "updates").apply { mkdirs() }
        return File(directory, "matter.apk").apply { writeBytes(byteArrayOf(4, 5, 6)) }
    }

    @Test
    fun exportsTheCompletedUpdateWithApkMimeType() {
        val provider = provider()
        val source = update()
        val uri = DownloadFileStore.saveUpdate(RuntimeEnvironment.getApplication(), source.path)
        val row = provider.rows.getValue(uri)
        assertEquals("matter.apk", row.getAsString(MediaStore.Downloads.DISPLAY_NAME))
        assertEquals("application/vnd.android.package-archive", row.getAsString(MediaStore.Downloads.MIME_TYPE))
        assertEquals(Environment.DIRECTORY_DOWNLOADS, row.getAsString(MediaStore.Downloads.RELATIVE_PATH))
        assertEquals(0, row.getAsInteger(MediaStore.Downloads.IS_PENDING))
        assertArrayEquals(source.readBytes(), provider.files.getValue(uri).readBytes())
        assertTrue(source.exists())
    }

    @Test
    fun failedUpdateExportsRemoveThePendingFile() {
        val provider = provider().apply { failWrite = true }
        assertThrows(IOException::class.java) {
            DownloadFileStore.saveUpdate(RuntimeEnvironment.getApplication(), update().path)
        }
        assertTrue(provider.rows.isEmpty())
    }

    @Test
    fun updateExportsRejectPrivateFilesAndUnfinishedDownloads() {
        val provider = provider()
        val context = RuntimeEnvironment.getApplication()
        val source = update()
        val privateFile = File(context.cacheDir, "private.apk").apply { writeText("private") }
        val partial = File(source.parentFile, "matter.apk.download").apply { writeText("partial") }
        for (file in listOf(privateFile, partial)) {
            assertThrows(IllegalArgumentException::class.java) { DownloadFileStore.saveUpdate(context, file.path) }
        }
        assertTrue(provider.rows.isEmpty())
    }

    @Test
    fun savesToPublicDownloadsAndPublishesOnlyAfterWriting() {
        val provider = provider()
        val uri = DownloadFileStore.save(RuntimeEnvironment.getApplication(), source().path)
        val row = provider.rows.getValue(uri)
        assertEquals(Environment.DIRECTORY_DOWNLOADS, row.getAsString(MediaStore.Downloads.RELATIVE_PATH))
        assertEquals("report.pdf", row.getAsString(MediaStore.Downloads.DISPLAY_NAME))
        assertEquals(0, row.getAsInteger(MediaStore.Downloads.IS_PENDING))
        assertArrayEquals(byteArrayOf(1, 2, 3), provider.files.getValue(uri).readBytes())
    }

    @Test
    fun failedWritesRemoveThePendingDownload() {
        val provider = provider().apply { failWrite = true }
        assertThrows(IOException::class.java) {
            DownloadFileStore.save(RuntimeEnvironment.getApplication(), source().path)
        }
        assertTrue(provider.rows.isEmpty())
    }

    @Test
    fun rejectsFilesOutsideTheDownloadStagingArea() {
        val provider = provider()
        val context = RuntimeEnvironment.getApplication()
        val privateFile = File(context.cacheDir, "private.txt").apply { writeText("private") }
        assertThrows(IllegalArgumentException::class.java) {
            DownloadFileStore.save(context, privateFile.path)
        }
        assertTrue(provider.rows.isEmpty())
    }
}
