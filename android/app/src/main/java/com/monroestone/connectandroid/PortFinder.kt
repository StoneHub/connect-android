package com.monroestone.connectandroid

import android.content.Context
import androidx.core.content.edit
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Finds the port adbd is using for wireless debugging by browsing for this
 * phone's own `_adb-tls-connect._tcp` mDNS service, the same record a Mac
 * would see on the LAN. The last good port is cached so the tile and widget
 * can show it immediately.
 */
class PortFinder(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("endpoint", Context.MODE_PRIVATE)

    fun cachedEndpoint(): Endpoint? {
        val port = prefs.getInt(KEY_PORT, 0).takeIf { it > 0 }
        return EndpointChooser.choose(localAddresses(), port)
    }

    fun clearCache() {
        prefs.edit { remove(KEY_PORT) }
    }

    /** Looks up the port off the main thread and reports on the main thread. */
    fun findAsync(onResult: (Endpoint?) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        executor.execute {
            val port = runCatching { discoverPort(DISCOVERY_TIMEOUT_MS) }.getOrNull()
            if (port != null) prefs.edit { putInt(KEY_PORT, port) }
            val endpoint = EndpointChooser.choose(localAddresses(), port)
            main.post { onResult(endpoint) }
        }
    }

    private fun discoverPort(timeoutMs: Long): Int? {
        val nsd = appContext.getSystemService(NsdManager::class.java) ?: return null
        val own = allLocalAddresses()
        val found = ArrayList<NsdServiceInfo>()
        val done = CountDownLatch(1)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(found) { found += info }
            }
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) = done.countDown()
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        done.await(timeoutMs, TimeUnit.MILLISECONDS)
        runCatching { nsd.stopServiceDiscovery(listener) }
        val candidates = synchronized(found) { found.toList() }
        // Resolve one at a time: NsdManager rejects overlapping resolves on older releases.
        for (candidate in candidates) {
            val resolved = resolve(nsd, candidate) ?: continue
            @Suppress("DEPRECATION")
            val host = resolved.host?.hostAddress ?: continue
            if (host.substringBefore('%') in own) return resolved.port
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun resolve(nsd: NsdManager, info: NsdServiceInfo): NsdServiceInfo? {
        var result: NsdServiceInfo? = null
        val done = CountDownLatch(1)
        nsd.resolveService(
            info,
            object : NsdManager.ResolveListener {
                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    result = resolved
                    done.countDown()
                }
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) = done.countDown()
            },
        )
        done.await(RESOLVE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        return result
    }

    /** IPv4 addresses on up, non-loopback interfaces (Wi-Fi and the Tailscale tunnel). */
    fun localAddresses(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .mapNotNull { it.hostAddress }
    }.getOrDefault(emptyList())

    private fun allLocalAddresses(): Set<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .flatMap { it.inetAddresses.toList() }
            .mapNotNull { it.hostAddress?.substringBefore('%') }
            .toSet()
    }.getOrDefault(emptySet())

    companion object {
        private const val SERVICE_TYPE = "_adb-tls-connect._tcp"
        private const val KEY_PORT = "port"
        private const val DISCOVERY_TIMEOUT_MS = 2_500L
        private const val RESOLVE_TIMEOUT_MS = 2_000L
        private val executor = Executors.newSingleThreadExecutor()
    }
}
