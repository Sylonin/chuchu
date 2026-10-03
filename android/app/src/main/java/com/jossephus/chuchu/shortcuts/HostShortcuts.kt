package com.jossephus.chuchu.shortcuts

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.jossephus.chuchu.MainActivity
import com.jossephus.chuchu.R
import com.jossephus.chuchu.model.HostProfile

/** Launcher (long-press app icon) shortcuts that open a saved server directly. */
object HostShortcuts {
    private const val ACTION_CONNECT_HOST = "com.jossephus.chuchu.action.CONNECT_HOST"
    private const val EXTRA_HOST_ID = "com.jossephus.chuchu.extra.HOST_ID"

    /** Returns the host id carried by a shortcut intent, or null for any other intent. */
    fun hostIdFrom(intent: Intent?): Long? {
        if (intent?.action != ACTION_CONNECT_HOST) return null
        val id = intent.getLongExtra(EXTRA_HOST_ID, NO_HOST)
        return id.takeIf { it != NO_HOST }
    }

    /**
     * Replaces the app's dynamic shortcuts with [hosts], in list order. Launchers
     * show only a few, and setDynamicShortcuts throws above the limit, so the
     * list is truncated to it.
     */
    fun publish(context: Context, hosts: List<HostProfile>) {
        val limit = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
        val shortcuts = hosts.take(limit).mapIndexed { index, host -> build(context, host, index) }
        ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)
    }

    private fun build(context: Context, host: HostProfile, rank: Int): ShortcutInfoCompat {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_CONNECT_HOST)
            .putExtra(EXTRA_HOST_ID, host.id)
        return ShortcutInfoCompat.Builder(context, "host-${host.id}")
            .setShortLabel(host.name)
            .setLongLabel("${host.name} (${host.username}@${host.host})")
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(intent)
            .setRank(rank)
            .build()
    }

    private const val NO_HOST = -1L
}
