package moe.aks.matter

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private var pendingInstallResult: MethodChannel.Result? = null
    private var pendingApkPath: String? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDownloadIntent(intent)
    }

    private fun handleDownloadIntent(intent: Intent?) {
        if (intent?.action != DownloadService.ACTION_INSTALL_UPDATE) return
        val path = intent.getStringExtra("path") ?: return
        intent.action = null
        requestInstall(
            path,
            object : MethodChannel.Result {
                override fun success(result: Any?) {}

                override fun notImplemented() {}

                override fun error(
                    code: String,
                    message: String?,
                    details: Any?,
                ) {
                    Toast.makeText(this@MainActivity, message ?: "无法安装更新", Toast.LENGTH_LONG).show()
                }
            },
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moe.aks.matter/downloads",
        ).setMethodCallHandler { call, result ->
            if (call.method !in listOf("start", "progress", "finish")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val id = if (call.method == "start") nextDownloadId.incrementAndGet() else call.argument<Int>("id")!!
                val command =
                    Intent(this, DownloadService::class.java).apply {
                        action = call.method
                        putExtra("id", id)
                        putExtra("filename", call.argument<String>("filename"))
                        putExtra("received", call.argument<Number>("received")?.toLong() ?: 0L)
                        putExtra("total", call.argument<Number>("total")?.toLong() ?: 0L)
                        putExtra("status", call.argument<String>("status"))
                        putExtra("error", call.argument<String>("error"))
                        putExtra("installPath", call.argument<String>("installPath"))
                    }
                if (call.method == "start") {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4109)
                    }
                    ContextCompat.startForegroundService(this, command)
                } else {
                    startService(command)
                }
                result.success(if (call.method == "start") id else null)
            } catch (error: Exception) {
                result.error("download_service_failed", "无法更新下载通知：${error.message}", null)
            }
        }
        handleDownloadIntent(intent)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "安装包路径无效", null)
                    } else {
                        requestInstall(path, result)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_SAVE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "下载文件路径无效", null)
                    } else {
                        requestFileSave(path, result)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun requestInstall(
        path: String,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            if (pendingInstallResult != null) {
                result.error("install_in_progress", "已有安装请求正在处理", null)
                return
            }
            pendingInstallResult = result
            pendingApkPath = path
            val intent =
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
            startActivityForResult(intent, INSTALL_PERMISSION_REQUEST)
            return
        }

        launchPackageInstaller(path, result)
    }

    @Deprecated("Deprecated by Android; retained for the package-install permission flow")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            INSTALL_PERMISSION_REQUEST -> {
                val result = pendingInstallResult
                val path = pendingApkPath
                pendingInstallResult = null
                pendingApkPath = null
                if (result == null || path == null) return

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !packageManager.canRequestPackageInstalls()
                ) {
                    result.error("install_permission_denied", "未授予安装未知应用权限", null)
                    return
                }
                launchPackageInstaller(path, result)
            }
        }
    }

    private fun requestFileSave(
        path: String,
        result: MethodChannel.Result,
    ) {
        fileSaveExecutor.execute {
            try {
                DownloadFileStore.save(applicationContext, path)
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("save_failed", "无法保存文件：${error.message}", null)
                }
            }
        }
    }

    private fun launchPackageInstaller(
        path: String,
        result: MethodChannel.Result,
    ) {
        try {
            val apkFile = File(path).canonicalFile
            val updateDirectory = File(cacheDir, "updates").canonicalFile
            if (!apkFile.isFile || apkFile.parentFile != updateDirectory) {
                result.error("invalid_apk", "找不到已下载的安装包", null)
                return
            }

            val apkUri =
                FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    apkFile,
                )
            val intent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(apkUri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("install_failed", "无法打开系统安装器：${error.message}", null)
        }
    }

    companion object {
        private val fileSaveExecutor = Executors.newSingleThreadExecutor()
        private val nextDownloadId = AtomicInteger((System.currentTimeMillis() % 1_000_000_000).toInt() + 1_000_000_000)
        private const val UPDATE_CHANNEL = "moe.aks.matter/app_update"
        private const val FILE_SAVE_CHANNEL = "moe.aks.matter/file_saver"
        private const val INSTALL_PERMISSION_REQUEST = 4107
    }
}
