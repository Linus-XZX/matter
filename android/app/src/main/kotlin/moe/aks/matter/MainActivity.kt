package moe.aks.matter

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingInstallResult: MethodChannel.Result? = null
    private var pendingApkPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                else -> result.notImplemented()
            }
        }
    }

    private fun requestInstall(path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            if (pendingInstallResult != null) {
                result.error("install_in_progress", "已有安装请求正在处理", null)
                return
            }
            pendingInstallResult = result
            pendingApkPath = path
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            startActivityForResult(intent, INSTALL_PERMISSION_REQUEST)
            return
        }

        launchPackageInstaller(path, result)
    }

    @Deprecated("Deprecated by Android; retained for the package-install permission flow")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != INSTALL_PERMISSION_REQUEST) return

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

    private fun launchPackageInstaller(path: String, result: MethodChannel.Result) {
        try {
            val apkFile = File(path).canonicalFile
            val updateDirectory = File(cacheDir, "updates").canonicalFile
            if (!apkFile.isFile || apkFile.parentFile != updateDirectory) {
                result.error("invalid_apk", "找不到已下载的安装包", null)
                return
            }

            val apkUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apkFile,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
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
        private const val UPDATE_CHANNEL = "moe.aks.matter/app_update"
        private const val INSTALL_PERMISSION_REQUEST = 4107
    }
}
