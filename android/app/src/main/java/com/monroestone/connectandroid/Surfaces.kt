package com.monroestone.connectandroid

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.service.quicksettings.TileService

/** Keeps the Quick Settings tile and every placed widget showing the same state. */
object Surfaces {

    fun refreshAll(context: Context) {
        refreshTile(context)
        DebugWidgetProvider.updateAll(context)
    }

    fun refreshTile(context: Context) {
        runCatching {
            TileService.requestListeningState(
                context,
                ComponentName(context, WirelessDebuggingTileService::class.java),
            )
        }
    }

    fun widgetIds(context: Context): IntArray = AppWidgetManager.getInstance(context)
        .getAppWidgetIds(ComponentName(context, DebugWidgetProvider::class.java))

    /**
     * Toggles wireless debugging. When turning it on, waits briefly for adbd to
     * advertise its port, then refreshes every surface with the endpoint.
     */
    fun toggle(context: Context, onDone: (() -> Unit)? = null) {
        val debugging = WirelessDebugging(context)
        val turnOn = !debugging.isOn()
        val finder = PortFinder(context)
        if (!debugging.setOn(turnOn)) {
            refreshAll(context)
            onDone?.invoke()
            return
        }
        if (!turnOn) finder.clearCache()
        refreshAll(context)
        if (turnOn) {
            finder.findAsync {
                refreshAll(context)
                onDone?.invoke()
            }
        } else {
            onDone?.invoke()
        }
    }
}
