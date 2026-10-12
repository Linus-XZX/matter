package moe.aks.matter

import android.app.ActivityManager
import android.app.KeyguardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.messaging.RemoteMessage
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal fun isMatterForeground(context: Context): Boolean {
    val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
    if (keyguard?.isKeyguardLocked == true) return false
    val activity = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
    return activity?.runningAppProcesses?.any {
        it.processName == context.packageName &&
            it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    } == true
}

/** Keep notification work inside FCM's service lifetime, including normal-priority delivery. */
class PushMessagingService : FlutterFirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        // The Flutter receiver delivers foreground messages to the existing onMessage stream.
        if (isMatterForeground(this)) return
        val completed = CountDownLatch(1)
        val data = message.data
        Handler(Looper.getMainLooper()).post {
            if (backgroundEngine == null) {
                val context = applicationContext
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(context)
                loader.ensureInitializationComplete(context, null)
                val engine = FlutterEngine(context)
                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                backgroundEngine = engine
                backgroundChannel = channel
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "ready") {
                        ready = true
                        result.success(null)
                        while (pending.isNotEmpty()) pending.removeFirst().invoke()
                    } else {
                        result.notImplemented()
                    }
                }
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        "package:matter/features/push/fcm_push_runtime.dart",
                        "matterFcmBackgroundDispatcher",
                    ),
                )
            }
            val deliver = {
                backgroundChannel!!.invokeMethod(
                    "message",
                    data,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            Log.i("MatterPush", "FCM background message processed")
                            completed.countDown()
                        }

                        override fun error(
                            code: String,
                            message: String?,
                            details: Any?,
                        ) {
                            Log.e("MatterPush", "FCM background message failed: $code")
                            completed.countDown()
                        }

                        override fun notImplemented() {
                            Log.e("MatterPush", "FCM background dispatcher is unavailable")
                            completed.countDown()
                        }
                    },
                )
            }
            if (ready) deliver() else pending.addLast(deliver)
        }
        // Firebase serializes service callbacks on a worker. Keep this callback alive
        // until Dart has finished instead of submitting a separate, quota-limited job.
        if (!completed.await(30, TimeUnit.SECONDS)) {
            Log.e("MatterPush", "FCM background message processing timed out")
        }
    }

    companion object {
        private const val CHANNEL = "moe.aks.matter/fcm_background"
        private var backgroundEngine: FlutterEngine? = null
        private var backgroundChannel: MethodChannel? = null
        private var ready = false
        private val pending = ArrayDeque<() -> Unit>()
    }
}
