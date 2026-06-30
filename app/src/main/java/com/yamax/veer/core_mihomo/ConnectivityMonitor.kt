package com.yamax.veer.core_mihomo

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.yamax.veer.core_logging.VeerLog

/**
 * Returns a "+" separated string of active transport names for this capabilities snapshot.
 * Uses integer literals for transport constants > API 29 to avoid lint warnings.
 */
private fun NetworkCapabilities.transportNames(): String {
    val labels = buildList {
        if (hasTransport(0)) add("CELL")       // TRANSPORT_CELLULAR
        if (hasTransport(1)) add("WIFI")       // TRANSPORT_WIFI
        if (hasTransport(2)) add("BT")         // TRANSPORT_BLUETOOTH
        if (hasTransport(3)) add("ETH")        // TRANSPORT_ETHERNET
        if (hasTransport(4)) add("VPN")        // TRANSPORT_VPN
        if (hasTransport(5)) add("WIFI_AWARE") // TRANSPORT_WIFI_AWARE
        if (hasTransport(6)) add("LOWPAN")     // TRANSPORT_LOWPAN
        if (hasTransport(7)) add("USB")        // TRANSPORT_USB  (API 31+)
        if (hasTransport(8)) add("THREAD")     // TRANSPORT_THREAD (API 34+)
        if (hasTransport(9)) add("SAT")        // TRANSPORT_SATELLITE (API 34+)
    }
    return if (labels.isEmpty()) "none" else labels.joinToString("+")
}

/**
 * Monitors physical network availability while the Mihomo core is running and
 * notifies [VeerVpnService] through two callbacks:
 *
 *   • [onUnderlyingNetworksChanged]: called whenever the set of usable physical
 *     networks changes. The service passes the array to
 *     [android.net.VpnService.setUnderlyingNetworks] so Android attributes traffic
 *     and battery correctly and routing metrics stay current.
 *
 *   • [onAllNetworksLost]: called when the last internet-capable physical network
 *     disappears. Mihomo's REST listener binds to 127.0.0.1, so the watchdog
 *     cannot detect this condition independently — ConnectivityMonitor fills that gap.
 *
 * Ownership: [VeerVpnService] creates exactly one instance inside [bootCore] (after
 * [coreRunning] is set to true) and calls [stop] inside [tearDownCore] after the
 * core has been stopped. Only one instance is live at a time; its lifetime mirrors
 * the core's running period.
 *
 * The request intentionally excludes VPN networks ([NetworkCapabilities.NET_CAPABILITY_NOT_VPN])
 * so the monitor tracks only physical transports and never observes its own tun interface.
 */
internal class ConnectivityMonitor(
    context: Context,
    private val onUnderlyingNetworksChanged: (Array<Network>) -> Unit,
    private val onAllNetworksLost: () -> Unit,
) {
    companion object {
        /**
         * Installed by [com.yamax.veer.testing.DebugLifecycleSetup] in debug builds.
         * Null in production — all event publishing short-circuits to a single null check.
         */
        @Volatile internal var eventObserver: ((ConnectivityEvent) -> Unit)? = null
    }

    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val activeNetworks = mutableSetOf<Network>()
    private val lock = Any()

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val snapshot: Array<Network>
            synchronized(lock) {
                activeNetworks.add(network)
                snapshot = activeNetworks.toTypedArray()
            }
            VeerLog.connectivity("network available (${snapshot.size} active)")
            val caps = connectivityManager.getNetworkCapabilities(network)
            eventObserver?.invoke(
                ConnectivityEvent.Available(
                    networkHandle = network.networkHandle,
                    transports    = caps?.transportNames() ?: "unknown",
                    validated     = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
                    timestampMs   = System.currentTimeMillis(),
                    threadName    = Thread.currentThread().name,
                )
            )
            onUnderlyingNetworksChanged(snapshot)
        }

        override fun onLost(network: Network) {
            val snapshot: Array<Network>
            synchronized(lock) {
                activeNetworks.remove(network)
                snapshot = activeNetworks.toTypedArray()
            }
            VeerLog.connectivity("network lost (${snapshot.size} remaining)")
            eventObserver?.invoke(
                ConnectivityEvent.Lost(
                    networkHandle  = network.networkHandle,
                    remainingCount = snapshot.size,
                    timestampMs    = System.currentTimeMillis(),
                    threadName     = Thread.currentThread().name,
                )
            )
            if (snapshot.isEmpty()) {
                onAllNetworksLost()
            } else {
                onUnderlyingNetworksChanged(snapshot)
            }
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            eventObserver?.invoke(
                ConnectivityEvent.CapabilitiesChanged(
                    networkHandle = network.networkHandle,
                    transports    = networkCapabilities.transportNames(),
                    validated     = networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                    captivePortal = networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
                    timestampMs   = System.currentTimeMillis(),
                    threadName    = Thread.currentThread().name,
                )
            )
        }

        override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
            eventObserver?.invoke(
                ConnectivityEvent.BlockedStatusChanged(
                    networkHandle = network.networkHandle,
                    blocked       = blocked,
                    timestampMs   = System.currentTimeMillis(),
                    threadName    = Thread.currentThread().name,
                )
            )
        }
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        runCatching {
            connectivityManager.registerNetworkCallback(request, networkCallback)
            VeerLog.connectivity("monitoring started")
        }.onFailure {
            VeerLog.connectivity("registerNetworkCallback failed: ${it.message}", VeerLog.Level.ERROR)
        }
    }

    fun stop() {
        runCatching {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        }
        synchronized(lock) { activeNetworks.clear() }
        VeerLog.connectivity("monitoring stopped")
    }
}
