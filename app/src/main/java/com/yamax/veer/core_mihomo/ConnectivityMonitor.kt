package com.yamax.veer.core_mihomo

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import com.yamax.veer.core_logging.VeerLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.net.Inet6Address
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Returns a "+" separated string of active transport names for this capabilities snapshot.
 * Newer transports are queried only on the API level that introduced them.
 */
private fun NetworkCapabilities.transportNames(): String {
    val labels = buildList {
        if (hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("CELL")
        if (hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("WIFI")
        if (hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) add("BT")
        if (hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("ETH")
        if (hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("VPN")
        if (hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE)) add("WIFI_AWARE")
        if (hasTransport(NetworkCapabilities.TRANSPORT_LOWPAN)) add("LOWPAN")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            hasTransport(NetworkCapabilities.TRANSPORT_USB)) add("USB")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            hasTransport(NetworkCapabilities.TRANSPORT_THREAD)) add("THREAD")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
            hasTransport(NetworkCapabilities.TRANSPORT_SATELLITE)) add("SAT")
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
    private val onSystemDnsChanged: (List<String>) -> Unit,
    private val onAllNetworksLost: () -> Unit,
) {
    internal data class Snapshot(
        val networks: Array<Network>,
        val dnsByNetwork: Map<Network, List<String>>,
    ) {
        val dnsServers: List<String>
            get() = networks.asSequence()
                .flatMap { dnsByNetwork[it].orEmpty().asSequence() }
                .distinct()
                .toList()
    }

    companion object {
        private const val ALL_NETWORKS_LOST_DEBOUNCE_MS = 2_000L

        /**
         * Installed by [com.yamax.veer.testing.DebugLifecycleSetup] in debug builds.
         * Null in production — all event publishing short-circuits to a single null check.
         */
        @Volatile internal var eventObserver: ((ConnectivityEvent) -> Unit)? = null
    }

    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val activeNetworks = mutableSetOf<Network>()
    private val dnsByNetwork = mutableMapOf<Network, List<String>>()
    private val lock = Any()
    private val started = AtomicBoolean(false)
    private var lastPublishedDns: List<String> = emptyList()
    private val lossDebouncer = SustainedNetworkLossDebouncer(
        scope = scope,
        debounceMs = ALL_NETWORKS_LOST_DEBOUNCE_MS,
        isStillLost = {
            synchronized(lock) { started.get() && activeNetworks.isEmpty() }
        },
        onSustainedLoss = {
            publishDnsIfChanged()
            VeerLog.connectivity(
                "all physical networks absent for ${ALL_NETWORKS_LOST_DEBOUNCE_MS}ms",
            )
            onAllNetworksLost()
        },
    )

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val snapshot: Array<Network>
            synchronized(lock) {
                activeNetworks.add(network)
                snapshot = activeNetworks.toTypedArray()
            }
            lossDebouncer.onNetworkAvailable()
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
                dnsByNetwork.remove(network)
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
                lossDebouncer.onAllNetworksAbsent()
            } else {
                publishDnsIfChanged()
                onUnderlyingNetworksChanged(snapshot)
            }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val snapshot: Array<Network>
            synchronized(lock) {
                if (network !in activeNetworks) return
                dnsByNetwork[network] = linkProperties.dnsServers.map(::formatDnsServer)
                snapshot = activeNetworks.toTypedArray()
            }
            publishDnsIfChanged()
            // A network handle may remain stable while its interface, routes or
            // DNS generation changes. Re-publish the snapshot so VpnService can
            // refresh its underlying-network preference without restarting TUN.
            onUnderlyingNetworksChanged(snapshot)
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

    /**
     * Captures the physical transports synchronously so the service can apply
     * their routing and DNS state before it publishes Running. Android delivers
     * the same networks again after callback registration; [start] seeds its
     * de-duplication state from this snapshot so those initial callbacks do not
     * reset Mihomo's DNS connections a second time.
     */
    fun captureCurrentSnapshot(): Snapshot {
        val dns = linkedMapOf<Network, List<String>>()
        val networks = connectivityManager.allNetworks.filter { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network)
                ?: return@filter false
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }
        for (network in networks) {
            dns[network] = connectivityManager.getLinkProperties(network)
                ?.dnsServers
                .orEmpty()
                .map(::formatDnsServer)
        }
        return Snapshot(networks.toTypedArray(), dns)
    }

    fun start(initialSnapshot: Snapshot = captureCurrentSnapshot()) {
        if (!started.compareAndSet(false, true)) return
        synchronized(lock) {
            activeNetworks.clear()
            activeNetworks.addAll(initialSnapshot.networks)
            dnsByNetwork.clear()
            dnsByNetwork.putAll(initialSnapshot.dnsByNetwork)
            lastPublishedDns = initialSnapshot.dnsServers
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        runCatching {
            connectivityManager.registerNetworkCallback(request, networkCallback)
            VeerLog.connectivity(
                "monitoring started with ${initialSnapshot.networks.size} network(s) " +
                    "and ${initialSnapshot.dnsServers.size} DNS server(s)",
            )
        }.onFailure {
            started.set(false)
            VeerLog.connectivity("registerNetworkCallback failed: ${it.message}", VeerLog.Level.ERROR)
        }
    }

    fun stop() {
        if (!started.getAndSet(false)) return
        lossDebouncer.cancel()
        runCatching {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        }
        scope.cancel()
        synchronized(lock) {
            activeNetworks.clear()
            dnsByNetwork.clear()
            lastPublishedDns = emptyList()
        }
        VeerLog.connectivity("monitoring stopped")
    }

    private fun publishDnsIfChanged() {
        val dns = synchronized(lock) {
            val next = activeNetworks.asSequence()
                .flatMap { dnsByNetwork[it].orEmpty().asSequence() }
                .distinct()
                .toList()
            if (next == lastPublishedDns) return
            lastPublishedDns = next
            next
        }
        VeerLog.connectivity("system DNS changed (${dns.size} server(s))")
        onSystemDnsChanged(dns)
    }

    private fun formatDnsServer(address: java.net.InetAddress): String {
        val host = address.hostAddress.orEmpty()
        return if (address is Inet6Address) "[$host]:53" else "$host:53"
    }

}
