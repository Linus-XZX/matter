package moe.aks.matter

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import androidx.annotation.Keep

/** Conversation avatars must be published before the notification references them. */
@Keep
object PushConversationShortcut {
    @JvmStatic
    fun publish(
        context: Context,
        id: String,
        title: String,
        avatarPath: String,
    ): Boolean {
        val avatar = BitmapFactory.decodeFile(avatarPath) ?: return false
        val shortcut =
            ShortcutInfo
                .Builder(context, id)
                .setShortLabel(title)
                .setLongLived(true)
                .setCategories(setOf("android.shortcut.conversation"))
                .setIcon(Icon.createWithBitmap(avatar))
                .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW))
        context.getSystemService(ShortcutManager::class.java).pushDynamicShortcut(shortcut.build())
        return true
    }
}
