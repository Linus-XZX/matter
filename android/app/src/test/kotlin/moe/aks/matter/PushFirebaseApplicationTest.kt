package moe.aks.matter

import android.app.Application
import android.content.Context
import com.google.firebase.FirebaseApp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], application = Application::class, manifest = Config.NONE)
class PushFirebaseApplicationTest {
    private fun applicationWithSavedOptions(options: String): PushFirebaseApplication {
        val context = RuntimeEnvironment.getApplication()
        FirebaseApp.getApps(context).forEach { it.delete() }
        context
            .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putString("flutter.fcm_firebase_options", options)
            .commit()
        val application = PushFirebaseApplication()
        ReflectionHelpers.callInstanceMethod<Any?>(
            application,
            "attach",
            ReflectionHelpers.ClassParameter.from(Context::class.java, context.baseContext),
        )
        return application
    }

    @Test
    fun restoresImportedProjectWithoutAnActivityOrDartEngine() {
        val application =
            applicationWithSavedOptions(
                """{"api_key":"test-key","app_id":"1:12345:android:abcdef","sender_id":"12345","project_id":"test-project"}""",
            )
        assertTrue(FirebaseApp.getApps(application).isEmpty())

        application.onCreate()

        val options = FirebaseApp.getInstance().options
        assertEquals("1:12345:android:abcdef", options.applicationId)
        assertEquals("12345", options.gcmSenderId)
        assertEquals("test-project", options.projectId)
        assertEquals("test-key", options.apiKey)
        FirebaseApp.getInstance().delete()
    }

    @Test
    fun malformedSavedOptionsDoNotCreateAnUnrelatedFirebaseProject() {
        val application = applicationWithSavedOptions("not json")
        application.onCreate()
        assertTrue(FirebaseApp.getApps(application).isEmpty())
    }
}
