package moe.aks.matter

import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver

/** Preserve Flutter's foreground stream; background data is handled by the FCM service. */
class PushMessageReceiver : FlutterFirebaseMessagingReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        intent.extras?.let { extras ->
            val message = RemoteMessage(extras)
            Log.i(
                "MatterPush",
                "FCM received: originalPriority=${message.originalPriority} " +
                    "deliveredPriority=${message.priority} " +
                    "gatewayPriority=${message.data["prio"]} " +
                    "eventType=${message.data["type"]} " +
                    "hasEvent=${!message.data["event_id"].isNullOrEmpty()} " +
                    "hasNotification=${message.notification != null}",
            )
        }
        if (isMatterForeground(context)) super.onReceive(context, intent)
    }
}
