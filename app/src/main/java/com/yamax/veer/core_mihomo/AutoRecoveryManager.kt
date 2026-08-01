package com.yamax.veer.core_mihomo

import android.content.Context
import com.yamax.veer.core_diagnostics.NetworkDiagnosticExecutor
import com.yamax.veer.data.ConfigManager
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit

internal class RecoveryFailureTracker(
    private val threshold: Int,
) {
    init {
        require(threshold > 0) { "threshold must be positive" }
    }

    var consecutiveFailures: Int = 0
        private set

    fun record(healthy: Boolean): Boolean {
        consecutiveFailures = if (healthy) 0 else consecutiveFailures + 1
        return !healthy && consecutiveFailures >= threshold
    }

    fun reset() {
        consecutiveFailures = 0
    }
}

internal sealed interface AutoRecoveryResult {
    data object Healthy : AutoRecoveryResult
    data class Degraded(val failures: Int) : AutoRecoveryResult
    data class Suppressed(val reason: String) : AutoRecoveryResult
    data class Recovered(
        val group: String,
        val previous: String?,
        val selected: String,
    ) : AutoRecoveryResult
    data class Unrecoverable(
        val group: String?,
        val attempted: List<String>,
        val selectionRestored: Boolean,
    ) : AutoRecoveryResult
}

/**
 * Recovers only proxy-exit failures. Runtime ownership remains in
 * [VeerVpnService]; this class never starts or stops Veercore or touches TUN.
 */
internal class AutoRecoveryManager(
    private val context: Context,
    private val mihomo: MihomoRepository = MihomoRepository.get(),
    failureThreshold: Int = 2,
    private val maxCandidates: Int = 3,
    private val internetProbe: suspend () -> Boolean = {
        defaultInternetProbe()
    },
) {
    private val tracker = RecoveryFailureTracker(failureThreshold)
    private var lastHealthyLeaf: String? = null

    suspend fun checkAndRecover(): AutoRecoveryResult {
        if (mihomo.version() == null) {
            tracker.reset()
            return AutoRecoveryResult.Suppressed("controller unavailable; watchdog owns recovery")
        }
        val probeRule = NetworkDiagnosticExecutor.matchingRule(
            rules = mihomo.rulesSnapshot(),
            domain = PROBE_DOMAIN,
            service = null,
        )
        if (probeRule?.proxy?.uppercase()?.startsWith("REJECT") == true) {
            tracker.reset()
            return AutoRecoveryResult.Suppressed(
                "probe target blocked by rule #${probeRule.index}",
            )
        }

        if (internetProbe()) {
            tracker.record(healthy = true)
            rememberHealthyLeaf()
            return AutoRecoveryResult.Healthy
        }
        if (!tracker.record(healthy = false)) {
            return AutoRecoveryResult.Degraded(tracker.consecutiveFailures)
        }

        val snapshot = mihomo.routingSnapshot()
        val policy = ConfigManager.runtimeDefaultPolicy(context)
        val group = policy?.let(snapshot.proxies::get)
            ?.takeIf { it.type == "Selector" }
            ?: snapshot.selectorGroups.firstOrNull { it.name != "GLOBAL" }
            ?: return AutoRecoveryResult.Unrecoverable(null, emptyList(), false).also {
                tracker.reset()
            }
        val previous = group.now
        val candidates = recoveryCandidates(snapshot, group)
        val attempted = mutableListOf<String>()

        for (candidate in candidates.take(maxCandidates)) {
            attempted += candidate.name
            if (!mihomo.selectProxy(group.name, candidate.name)) continue
            delay(500)
            if (internetProbe()) {
                tracker.reset()
                lastHealthyLeaf = candidate.name
                return AutoRecoveryResult.Recovered(group.name, previous, candidate.name)
            }
        }

        val restored = previous != null && mihomo.selectProxy(group.name, previous)
        return AutoRecoveryResult.Unrecoverable(group.name, attempted, restored).also {
            // Exhaustion is a transient data-plane condition, not a dead core.
            // Require a fresh consecutive-failure window before trying again.
            tracker.reset()
        }
    }

    private suspend fun recoveryCandidates(
        snapshot: MihomoRepository.RoutingSnapshot,
        group: MihomoRepository.ProxyState,
    ): List<MihomoRepository.ProxyState> {
        val candidates = snapshot.switchCandidates(group.name).toMutableList()
        lastHealthyLeaf
            ?.let(snapshot.proxies::get)
            ?.takeIf { it.name in group.members && it.alive != false }
            ?.let { candidates.add(0, it) }
        val bounded = candidates.distinctBy { it.name }
            .sortedWith(
                compareBy<MihomoRepository.ProxyState> {
                    if (it.name == lastHealthyLeaf) 0 else 1
                }.thenBy { it.delayMs ?: Int.MAX_VALUE },
            )
            .take(MAX_PROBE_CANDIDATES)
        return coroutineScope {
            bounded.map { candidate ->
                async {
                    mihomo.probeProxyDelay(candidate.name, timeoutMs = 2_500)
                        ?.let { candidate.copy(delayMs = it) }
                }
            }.awaitAll().filterNotNull()
        }
            .sortedWith(
                compareBy<MihomoRepository.ProxyState> {
                    if (it.name == lastHealthyLeaf) 0 else 1
                }.thenBy { it.delayMs ?: Int.MAX_VALUE },
            )
    }

    private suspend fun rememberHealthyLeaf() {
        val snapshot = mihomo.routingSnapshot()
        val policy = ConfigManager.runtimeDefaultPolicy(context)
        val group = policy?.let(snapshot.proxies::get)
            ?.takeIf { it.type == "Selector" }
            ?: return
        snapshot.resolvedLeaf(group.name)
            ?.takeIf { it.alive != false }
            ?.let { lastHealthyLeaf = it.name }
    }

    companion object {
        private const val PROBE_DOMAIN = "www.gstatic.com"
        private const val PROBE_URL = "https://www.gstatic.com/generate_204"
        private const val MIXED_PORT = 7890
        private const val MAX_PROBE_CANDIDATES = 8

        private fun defaultInternetProbe(): Boolean {
            val client = OkHttpClient.Builder()
                .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", MIXED_PORT)))
                .connectTimeout(3, TimeUnit.SECONDS)
                .readTimeout(4, TimeUnit.SECONDS)
                .callTimeout(5, TimeUnit.SECONDS)
                .build()
            return runCatching {
                client.newCall(
                    Request.Builder()
                        .url(PROBE_URL)
                        .header("Connection", "close")
                        .get()
                        .build(),
                ).execute().use { it.code == 204 || it.isSuccessful }
            }.getOrDefault(false)
        }
    }
}
