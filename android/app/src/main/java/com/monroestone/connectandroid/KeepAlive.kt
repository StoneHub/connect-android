package com.monroestone.connectandroid

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import androidx.core.content.edit
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper

/**
 * Android turns wireless debugging off whenever Wi-Fi drops. With keep-alive
 * on, [AdbSettingWatcher] notices the setting flip while Wi-Fi is gone and
 * arms a one-shot PendingIntent network callback. When Wi-Fi returns the
 * system wakes [WifiReceiver], which turns wireless debugging back on. Nothing
 * runs in between, and ConnectivityService releases the callback after it
 * fires, so it never repeats while Wi-Fi stays up. Turning debugging off by
 * hand while on Wi-Fi is respected.
 */
object KeepAlive {

    private const val PREFS = "keep_alive"
    private const val KEY_ON = "on"
    private const val SETTLE_DELAY_MS = 3_000L

    fun isOn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ON, false)

    fun setOn(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(KEY_ON, on) }
        if (on) {
            AdbSettingWatcher.schedule(context)
            if (!enableIfPossible(context) && !onWifi(context)) arm(context)
        } else {
            unregister(context)
        }
    }

    /** After a reboot or update: watch the setting again and catch the next Wi-Fi connection. */
    fun rearm(context: Context) {
        if (!isOn(context)) return
        AdbSettingWatcher.schedule(context)
        if (!enableIfPossible(context) && !onWifi(context)) arm(context)
    }

    /** Called when wireless debugging turned off; only re-arms if Android did it because Wi-Fi left. */
    fun onDebuggingTurnedOff(context: Context) {
        if (isOn(context) && !onWifi(context)) arm(context)
    }

    fun enableIfPossible(context: Context): Boolean {
        val debugging = WirelessDebugging(context)
        if (!isOn(context) || debugging.isOn()) return false
        if (!debugging.canWriteSecureSettings() || !debugging.developerOptionsOn()) return false
        if (!onWifi(context)) return false
        return debugging.setOn(true).also { if (it) Surfaces.refreshAll(context) }
    }

    @Suppress("DEPRECATION")
    fun onWifi(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
        // The active network is often the Tailscale VPN, so look at every network.
        return cm.allNetworks.any { network ->
            cm.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    /** One-shot: fires once on the next Wi-Fi connection, then the system releases it. */
    private fun arm(context: Context) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        runCatching { cm.registerNetworkCallback(request, pendingIntent(context)) }
    }

    private fun unregister(context: Context) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        runCatching { cm.unregisterNetworkCallback(pendingIntent(context)) }
    }

    // Mutable so the system can attach the Network extra; the intent is explicit to this app.
    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        1,
        Intent(context, WifiReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    class WifiReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val pending = goAsync()
            // Give Android a moment to finish its own network-change handling first.
            Handler(Looper.getMainLooper()).postDelayed({
                enableIfPossible(context)
                pending.finish()
            }, SETTLE_DELAY_MS)
        }
    }

    /** Boot and app-update hook. */
    class RearmReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                    rearm(context)
                    if (Surfaces.widgetIds(context).isNotEmpty()) AdbSettingWatcher.schedule(context)
                }
            }
        }
    }
}
