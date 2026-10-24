package moe.aks.matter

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider

/** Opens system-owned installation and download UIs without a pre-emptive settings redirect. */
internal object UpdateInstaller {
    fun install(
        context: Context,
        path: String,
    ) {
        val apk = DownloadFileStore.updateApk(context, path)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", apk)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    fun openDownloads(context: Context) {
        context.startActivity(
            Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
