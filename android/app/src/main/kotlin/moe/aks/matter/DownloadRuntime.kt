package moe.aks.matter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Retains the downloading isolate when its Activity is destroyed and reuses it on return. */
internal object DownloadRuntime {
    var engine: FlutterEngine? = null
        private set

    private var host: FlutterActivity? = null
    private val transfers = mutableSetOf<Int>()

    fun retain(
        id: Int,
        candidate: FlutterEngine,
        activity: FlutterActivity,
    ) {
        check(engine == null || engine === candidate) { "Downloads already belong to another engine" }
        engine = candidate
        transfers.add(id)
        attachHost(activity, candidate)
    }

    fun attachHost(
        activity: FlutterActivity,
        candidate: FlutterEngine,
    ) {
        if (engine === candidate && !activity.isDestroyed) host = activity
    }

    fun detachHost(activity: FlutterActivity) {
        if (host === activity) host = null
    }

    fun ownsEngine(candidate: FlutterEngine?): Boolean = engine != null && engine === candidate

    fun finish(id: Int) {
        if (transfers.remove(id) && transfers.isEmpty()) release()
    }

    fun release() {
        val retained = engine
        val detached = host == null
        engine = null
        host = null
        transfers.clear()
        if (detached) retained?.destroy()
    }
}
