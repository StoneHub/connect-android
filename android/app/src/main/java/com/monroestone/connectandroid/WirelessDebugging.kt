package com.monroestone.connectandroid

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings

/**
 * Reads and writes the global settings behind Developer options → Wireless
 * debugging. Writing needs WRITE_SECURE_SETTINGS, which only adb (or the Mac
 * app over adb) can grant. The grant survives app updates and is removed on
 * uninstall.
 */
class WirelessDebugging(context: Context) {

    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver

    fun canWriteSecureSettings(): Boolean =
        appContext.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    fun developerOptionsOn(): Boolean =
        Settings.Global.getInt(resolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1

    fun isOn(): Boolean = Settings.Global.getInt(resolver, ADB_WIFI_ENABLED, 0) == 1

    /** Returns false when the permission is missing or Android rejects the write. */
    fun setOn(on: Boolean): Boolean {
        if (!canWriteSecureSettings()) return false
        return runCatching { Settings.Global.putInt(resolver, ADB_WIFI_ENABLED, if (on) 1 else 0) }
            .getOrDefault(false)
    }

    /** Android revokes computer authorizations after 7 days of disuse unless this is 0. */
    fun pairingsExpire(): Boolean =
        Settings.Global.getLong(resolver, ADB_ALLOWED_CONNECTION_TIME, DEFAULT_ALLOWED_CONNECTION_TIME_MS) != 0L

    fun setPairingsExpire(expire: Boolean): Boolean {
        if (!canWriteSecureSettings()) return false
        val value = if (expire) DEFAULT_ALLOWED_CONNECTION_TIME_MS else 0L
        return runCatching { Settings.Global.putLong(resolver, ADB_ALLOWED_CONNECTION_TIME, value) }
            .getOrDefault(false)
    }

    fun state(endpoint: Endpoint?): DebugState = DebugState.from(
        canWriteSecureSettings = canWriteSecureSettings(),
        developerOptionsOn = developerOptionsOn(),
        wirelessDebuggingOn = isOn(),
        endpoint = endpoint,
    )

    companion object {
        const val ADB_WIFI_ENABLED = "adb_wifi_enabled"
        private const val ADB_ALLOWED_CONNECTION_TIME = "adb_allowed_connection_time"
        private const val DEFAULT_ALLOWED_CONNECTION_TIME_MS = 7L * 24 * 60 * 60 * 1000

        val enabledUri: Uri get() = Settings.Global.getUriFor(ADB_WIFI_ENABLED)

        fun grantCommand(packageName: String): String =
            "adb shell pm grant $packageName ${Manifest.permission.WRITE_SECURE_SETTINGS}"
    }
}
