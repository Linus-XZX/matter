package moe.aks.matter

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.net.URLConnection

internal object DownloadFileStore {
    fun save(
        context: Context,
        path: String,
    ): Uri {
        val source = File(path).canonicalFile
        val stagingDirectory = File(context.cacheDir, "matter_downloads").canonicalFile
        require(source.isFile && source.parentFile?.parentFile == stagingDirectory) {
            "找不到待保存的下载文件"
        }
        val values =
            ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, source.name)
                put(MediaStore.Downloads.MIME_TYPE, URLConnection.guessContentTypeFromName(source.name) ?: "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
        val resolver = context.contentResolver
        val destination =
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("无法创建下载文件")
        try {
            resolver.openOutputStream(destination)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: error("无法打开下载目录")
            resolver.update(
                destination,
                ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                },
                null,
                null,
            )
            return destination
        } catch (error: Exception) {
            resolver.delete(destination, null, null)
            throw error
        }
    }
}
