package moe.aks.matter

import android.app.Application
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.Icon
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.util.ReflectionHelpers
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], application = Application::class, manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PushConversationShortcutTest {
    private fun avatar(): File {
        val context = RuntimeEnvironment.getApplication()
        val file = File(context.cacheDir, "room.png")
        val bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.BLUE)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return file
    }

    @Test
    fun publishesAndUpdatesTheRoomIdentity() {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(ShortcutManager::class.java)
        val id = "matrix:@alice:example.org:!room:example.org"
        val path = avatar().path
        assertTrue(PushConversationShortcut.publish(context, id, "Room", path))
        val first = manager.dynamicShortcuts.single()
        assertEquals(id, first.id)
        assertEquals("Room", first.shortLabel)
        assertTrue(ReflectionHelpers.callInstanceMethod<Boolean>(first, "isLongLived"))
        assertTrue(ReflectionHelpers.callInstanceMethod<Icon>(first, "getIcon") != null)
        assertTrue(PushConversationShortcut.publish(context, id, "Renamed", path))
        val updated = manager.dynamicShortcuts.single()
        assertEquals(id, updated.id)
        assertEquals("Renamed", updated.shortLabel)
    }

    @Test
    fun missingOrInvalidAvatarDoesNotPublishAFalseIdentity() {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(ShortcutManager::class.java)
        val file = File(context.cacheDir, "missing.png")
        assertFalse(PushConversationShortcut.publish(context, "room", "Room", file.path))
        file.writeText("not an image")
        assertFalse(PushConversationShortcut.publish(context, "room", "Room", file.path))
        assertTrue(manager.dynamicShortcuts.isEmpty())
    }
}
