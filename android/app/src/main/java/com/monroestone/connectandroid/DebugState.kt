package com.monroestone.connectandroid

/** Where a Mac can reach this phone's wireless-debugging service. */
data class Endpoint(val host: String, val port: Int) {
    val address: String get() = "$host:$port"
    val connectCommand: String get() = "adb connect $address"
}

/** Everything the tile, widget, and setup screen show. Free of Android types for unit tests. */
sealed interface DebugState {
    /** WRITE_SECURE_SETTINGS has not been granted from a computer yet. */
    data object NeedsPermission : DebugState

    /** Wireless debugging cannot run until Developer options is turned on. */
    data object DeveloperOptionsOff : DebugState

    data object Off : DebugState

    /** [endpoint] is null while the port is still being discovered or when not on a network. */
    data class On(val endpoint: Endpoint?) : DebugState

    val isOn: Boolean get() = this is On

    companion object {
        fun from(
            canWriteSecureSettings: Boolean,
            developerOptionsOn: Boolean,
            wirelessDebuggingOn: Boolean,
            endpoint: Endpoint?,
        ): DebugState = when {
            !developerOptionsOn -> DeveloperOptionsOff
            wirelessDebuggingOn -> On(endpoint)
            !canWriteSecureSettings -> NeedsPermission
            else -> Off
        }
    }
}

/**
 * Chooses which of the phone's addresses to advertise. A Tailscale address
 * (100.64.0.0/10) works from anywhere on the tailnet, so it wins over Wi-Fi.
 */
object EndpointChooser {
    fun choose(addresses: List<String>, port: Int?): Endpoint? {
        if (port == null || port !in 1..65_535) return null
        val host = addresses.firstOrNull(::isTailscale)
            ?: addresses.firstOrNull(::isPrivateLan)
            ?: addresses.firstOrNull()
            ?: return null
        return Endpoint(host, port)
    }

    fun isTailscale(address: String): Boolean {
        val octets = ipv4Octets(address) ?: return false
        return octets[0] == 100 && octets[1] in 64..127
    }

    fun isPrivateLan(address: String): Boolean {
        val octets = ipv4Octets(address) ?: return false
        return octets[0] == 10 ||
            (octets[0] == 172 && octets[1] in 16..31) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private fun ipv4Octets(address: String): List<Int>? {
        val parts = address.split('.')
        if (parts.size != 4) return null
        val octets = parts.map { it.toIntOrNull() ?: return null }
        return octets.takeIf { all -> all.all { it in 0..255 } }
    }
}
