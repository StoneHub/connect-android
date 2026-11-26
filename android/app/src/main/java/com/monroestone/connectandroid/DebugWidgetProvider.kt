package com.monroestone.connectandroid

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import androidx.core.content.ContextCompat

class DebugWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
        AdbSettingWatcher.schedule(context)
    }

    override fun onDisabled(context: Context) {
        if (!KeepAlive.isOn(context)) AdbSettingWatcher.cancel(context)
    }

    companion object {
        fun updateAll(context: Context) {
            val ids = Surfaces.widgetIds(context)
            if (ids.isEmpty()) return
            val manager = AppWidgetManager.getInstance(context)
            render(context, manager, ids)
            val debugging = WirelessDebugging(context)
            if (debugging.isOn() && PortFinder(context).cachedEndpoint() == null) {
                PortFinder(context).findAsync { endpoint ->
                    if (endpoint != null) render(context, manager, ids)
                }
            }
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val state = WirelessDebugging(context).state(PortFinder(context).cachedEndpoint())
            val views = RemoteViews(context.packageName, R.layout.widget_debug)
            val on = state.isOn
            val foreground = ContextCompat.getColor(context, if (on) R.color.on_accent else R.color.on_surface)
            val secondary = ContextCompat.getColor(
                context,
                if (on) R.color.on_accent_secondary else R.color.on_surface_secondary,
            )
            val text = StateText(context)
            views.setInt(
                R.id.widgetRoot,
                "setBackgroundResource",
                if (on) R.drawable.widget_background_on else R.drawable.widget_background,
            )
            views.setImageViewResource(
                R.id.widgetIcon,
                if (on || state == DebugState.Off) R.drawable.ic_adb_wifi else R.drawable.ic_adb_locked,
            )
            views.setInt(R.id.widgetIcon, "setColorFilter", foreground)
            views.setTextViewText(
                R.id.widgetTitle,
                context.getString(if (on) R.string.widget_title_on else R.string.widget_title_off),
            )
            views.setTextColor(R.id.widgetTitle, foreground)
            views.setTextViewText(
                R.id.widgetDetail,
                if (state == DebugState.Off) context.getString(R.string.widget_detail_off) else text.detail(state),
            )
            views.setTextColor(R.id.widgetDetail, secondary)
            views.setContentDescription(
                R.id.widgetRoot,
                context.getString(R.string.widget_content_description, text.detail(state)),
            )
            val tap = when (state) {
                DebugState.NeedsPermission, DebugState.DeveloperOptionsOff -> PendingIntent.getActivity(
                    context,
                    0,
                    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                else -> PendingIntent.getBroadcast(
                    context,
                    0,
                    Intent(context, ToggleReceiver::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            views.setOnClickPendingIntent(R.id.widgetRoot, tap)
            manager.updateAppWidget(ids, views)
        }
    }
}
