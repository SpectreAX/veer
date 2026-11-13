package com.yamax.veer.data

import android.content.Context
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_mihomo.MihomoLocalProxy
import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import kotlin.system.measureTimeMillis

internal data class ExitIdentity(
    val ipv4: String? = null,
    val ipv6: String? = null,
    val countryCode: String? = null,
    val country: String? = null,
    val region: String? = null,
    val city: String? = null,
) {
    val locationLabel: String
        get() = listOfNotNull(
            countryCode?.uppercase(),
            region,
            city,
        ).distinct().joinToString(" · ").ifEmpty { country ?: "未知地区" }
}

data class SpeedSample(
    val timestamp: Long,
    val uploadSpeed: Long,
    val downloadSpeed: Long,
)

internal class SpeedHistoryBuffer(
    private val maxSamples: Int = 60,
    private val historyWindowMs: Long = 60_000L,
) {
    init {
        require(maxSamples > 0)
        require(historyWindowMs > 0)
    }

    private val samples = ArrayDeque<SpeedSample>(maxSamples + 1)

    fun append(sample: SpeedSample): List<SpeedSample> {
        val sanitized = sample.copy(
            uploadSpeed = sample.uploadSpeed.coerceAtLeast(0L),
            downloadSpeed = sample.downloadSpeed.coerceAtLeast(0L),
        )
        prune(sanitized.timestamp)
        samples.addLast(sanitized)
        while (samples.size > maxSamples) {
            samples.removeFirst()
        }
        return snapshot()
    }

    fun prune(nowMs: Long): List<SpeedSample> {
        val cutoff = nowMs - historyWindowMs
        while (samples.firstOrNull()?.timestamp?.let { it < cutoff } == true) {
            samples.removeFirst()
        }
        return snapshot()
    }

    fun clear(): List<SpeedSample> {
        samples.clear()
        return emptyList()
    }

    fun snapshot(): List<SpeedSample> = samples.toList()
}

internal fun calculateSpeedSample(
    previousUploadTotal: Long,
    previousDownloadTotal: Long,
    currentUploadTotal: Long,
    currentDownloadTotal: Long,
    previousTimestampMs: Long,
    currentTimestampMs: Long,
    maxSampleGapMs: Long = 5_000L,
): SpeedSample? {
    val elapsedMs = currentTimestampMs - previousTimestampMs
    if (previousTimestampMs <= 0L || elapsedMs !in 1..maxSampleGapMs) return null
    if (
        currentUploadTotal < previousUploadTotal ||
        currentDownloadTotal < previousDownloadTotal
    ) {
        return null
    }

    fun bytesPerSecond(delta: Long): Long =
        ((delta.toDouble() * 1_000.0) / elapsedMs.toDouble())
            .coerceIn(0.0, Long.MAX_VALUE.toDouble())
            .toLong()

    return SpeedSample(
        timestamp = currentTimestampMs,
        uploadSpeed = bytesPerSecond(currentUploadTotal - previousUploadTotal),
        downloadSpeed = bytesPerSecond(currentDownloadTotal - previousDownloadTotal),
    )
}

internal data class ConnectionHomeStatus(
    val controllerReachable: Boolean = false,
    val internetReachable: Boolean = false,
    val internetLatencyMs: Long? = null,
    val exit: ExitIdentity = ExitIdentity(),
    val selectedPolicy: String? = null,
    val selectedNode: String? = null,
    val nodeDelayMs: Int? = null,
    val uploadTotal: Long = 0,
    val downloadTotal: Long = 0,
    val activeConnections: Int = 0,
    val activeRuleCount: Int = 0,
    val runtimeMode: String? = null,
)

internal class ConnectionStatusRepository(
    private val context: Context,
    private val mihomo: MihomoRepository = MihomoRepository.get(),
    private val tunnelClient: OkHttpClient = defaultTunnelClient(),
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    @Volatile private var cachedExit = ExitIdentity()
    @Volatile private var cachedExitAtMs = 0L
    @Volatile private var cachedExitRouteKey: String? = null
    @Volatile private var activeTunnelRouteKey: String? = null
    @Volatile private var cachedDefaultPolicy: String? = null
    @Volatile private var configurationLoaded = false

    private val speedBuffer = SpeedHistoryBuffer()
    private val _speedHistory = MutableStateFlow<List<SpeedSample>>(emptyList())
    val speedHistory: StateFlow<List<SpeedSample>> = _speedHistory.asStateFlow()
    private var lastTrafficTime = 0L

    @Synchronized
    private fun updateSpeedHistory(
        previous: ConnectionHomeStatus,
        currentUpload: Long,
        currentDownload: Long,
    ) {
        val now = SystemClock.elapsedRealtime()
        if (
            currentUpload < previous.uploadTotal ||
            currentDownload < previous.downloadTotal
        ) {
            _speedHistory.value = speedBuffer.clear()
        } else {
            val sample = calculateSpeedSample(
                previousUploadTotal = previous.uploadTotal,
                previousDownloadTotal = previous.downloadTotal,
                currentUploadTotal = currentUpload,
                currentDownloadTotal = currentDownload,
                previousTimestampMs = lastTrafficTime,
                currentTimestampMs = now,
            )
            _speedHistory.value = if (sample == null) {
                speedBuffer.prune(now)
            } else {
                speedBuffer.append(sample)
            }
        }
        lastTrafficTime = now
    }

    /**
     * Starts a foreground sampling window without averaging time spent in the
     * background into the next visible data point.
     */
    @Synchronized
    fun resumeSpeedSampling() {
        val now = SystemClock.elapsedRealtime()
        lastTrafficTime = 0L
        _speedHistory.value = speedBuffer.prune(now)
    }

    /** Clears both the visible history and its counter baseline on disconnect. */
    @Synchronized
    fun resetSpeedHistory() {
        lastTrafficTime = 0L
        _speedHistory.value = speedBuffer.clear()
    }

    /**
     * Full dashboard refresh. Network probes are intentionally kept out of the
     * steady-state one-second path and run on launch, runtime mutations, resume,
     * and a slow background cadence.
     */
    suspend fun snapshot(
        previous: ConnectionHomeStatus = ConnectionHomeStatus(),
    ): ConnectionHomeStatus {
        refreshConfiguredPolicy()
        return networkSnapshot(lightweightSnapshot(previous))
    }

    /**
     * Binder-only live counters and route selection. No localhost JSON, DNS or
     * public network request is performed here.
     */
    suspend fun lightweightSnapshot(
        previous: ConnectionHomeStatus,
    ): ConnectionHomeStatus = coroutineScope {
        val traffic = async { runCatching { mihomo.trafficSnapshot() }.getOrNull() }
        if (!configurationLoaded) {
            refreshConfiguredPolicy()
        }
        val route = runCatching {
            mihomo.dashboardRoutingSnapshot(cachedDefaultPolicy)
        }.getOrNull()
        val routeKey = routeKey(route?.policy, route?.selectedNode)
        // evictAll() can close live TLS sockets and perform network I/O. Keep
        // it off Compose's main dispatcher even though it usually returns
        // immediately.
        withContext(Dispatchers.IO) {
            prepareTunnelClientForRoute(routeKey)
        }
        val trafficSnapshot = traffic.await()

        val newUpload = trafficSnapshot?.uploadTotal ?: previous.uploadTotal
        val newDownload = trafficSnapshot?.downloadTotal ?: previous.downloadTotal
        if (trafficSnapshot != null) {
            updateSpeedHistory(previous, newUpload, newDownload)
        }

        previous.copy(
            controllerReachable = route?.coreRunning == true,
            selectedPolicy = route?.policy,
            selectedNode = route?.selectedNode,
            nodeDelayMs = route?.nodeDelayMs,
            uploadTotal = newUpload,
            downloadTotal = newDownload,
            activeConnections =
                trafficSnapshot?.activeConnections ?: previous.activeConnections,
            runtimeMode = route?.mode,
        )
    }

    /** One-second UI path: a single bounded traffic IPC call only. */
    suspend fun trafficSnapshot(
        previous: ConnectionHomeStatus,
    ): ConnectionHomeStatus {
        val traffic = runCatching { mihomo.trafficSnapshot() }.getOrNull()
            ?: return previous

        updateSpeedHistory(previous, traffic.uploadTotal, traffic.downloadTotal)

        return previous.copy(
            uploadTotal = traffic.uploadTotal,
            downloadTotal = traffic.downloadTotal,
            activeConnections = traffic.activeConnections,
        )
    }

    /** Performs the expensive Internet, exit identity and rule-store checks. */
    suspend fun networkSnapshot(
        base: ConnectionHomeStatus,
    ): ConnectionHomeStatus = coroutineScope {
        val rules = async(Dispatchers.IO) {
            runCatching {
                ConfigManager.aiRulesSnapshot(context).rules.count {
                    it.enabled && it.policyAvailable && it.loadedInMaterializedConfig
                }
            }.getOrDefault(base.activeRuleCount)
        }
        val routeKey = routeKey(base.selectedPolicy, base.selectedNode)
        val internet = async(Dispatchers.IO) { probeInternet() }
        val exit = async(Dispatchers.IO) { cachedOrFetchExitIdentity(routeKey) }
        val internetResult = internet.await()
        base.copy(
            internetReachable = internetResult.first,
            internetLatencyMs = internetResult.second,
            exit = exit.await(),
            activeRuleCount = rules.await(),
        )
    }

    private suspend fun refreshConfiguredPolicy() {
        cachedDefaultPolicy = withContext(Dispatchers.IO) {
            ConfigManager.runtimeDefaultPolicy(context)
        }
        configurationLoaded = true
    }

    private fun routeKey(policy: String?, selectedNode: String?): String =
        "${policy.orEmpty()}\u0000${selectedNode.orEmpty()}"

    private fun probeInternet(): Pair<Boolean, Long?> {
        var successful = false
        val elapsed = measureTimeMillis {
            successful = runCatching {
                // Veer is excluded from its own TUN to avoid a routing loop.
                // Explicitly enter Mihomo through its local mixed port so this
                // probe validates the selected node and active rules instead
                // of only validating the Android host network.
                tunnelClient.newCall(
                    Request.Builder()
                        .url(INTERNET_PROBE_URL)
                        .header("Cache-Control", "no-cache")
                        .get()
                        .build(),
                ).execute().use { it.code == 204 || it.isSuccessful }
            }.getOrDefault(false)
        }
        return successful to elapsed.takeIf { successful }
    }

    private fun fetchExitIdentity(): ExitIdentity {
        val ipv4Body = getBody(IPV4_ENDPOINT)
            ?: getBody(IPV4_FALLBACK_ENDPOINT)
        val ipv6Body = getBody(IPV6_ENDPOINT)
        val geoBody = getBody(GEO_ENDPOINT)
            ?: getBody(GEO_SECONDARY_ENDPOINT)
            ?: getBody(GEO_FALLBACK_ENDPOINT)
        return parseExitIdentity(ipv4Body, ipv6Body, geoBody, json)
    }

    private fun cachedOrFetchExitIdentity(routeKey: String): ExitIdentity {
        val now = System.currentTimeMillis()
        if (shouldReuseExitIdentity(now, cachedExitAtMs, routeKey, cachedExitRouteKey, cachedExit)) {
            return cachedExit
        }
        return fetchExitIdentity().also { latest ->
            if (latest.ipv4 != null || latest.ipv6 != null) {
                cachedExit = latest
                cachedExitAtMs = now
                cachedExitRouteKey = routeKey
            }
        }
    }

    @Synchronized
    private fun prepareTunnelClientForRoute(routeKey: String) {
        val previous = activeTunnelRouteKey
        if (previous != null && previous != routeKey) {
            // Existing HTTP/2 tunnels continue through the node on which they
            // were created. Discard them once on a route change so exit checks
            // observe the new node, but keep them warm during steady state.
            tunnelClient.connectionPool.evictAll()
        }
        activeTunnelRouteKey = routeKey
    }

    private fun getBody(url: String): String? = runCatching {
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json,text/plain;q=0.9,*/*;q=0.8")
            .header(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/138.0 Mobile Safari/537.36",
            )
            .get()
            .build()
        tunnelClient.newCall(request).execute().use { response ->
            response.body?.string()?.takeIf { response.isSuccessful }
        }
    }.getOrNull()

    companion object {
        private const val INTERNET_PROBE_URL = "https://www.gstatic.com/generate_204"
        private const val IPV4_ENDPOINT = "https://ipv4-ip.api.skk.moe/v1/home"
        private const val IPV6_ENDPOINT = "https://ipv6-ip.api.skk.moe/v1/home"
        private const val GEO_ENDPOINT = "https://www.cloudflare.com/cdn-cgi/trace"
        private const val GEO_SECONDARY_ENDPOINT = "https://ip.api.skk.moe/cf-geoip"
        private const val IPV4_FALLBACK_ENDPOINT = "https://api.ipify.org?format=json"
        private const val GEO_FALLBACK_ENDPOINT = "https://ipapi.co/json/"
        internal const val EXIT_CACHE_MS = 60_000L

        private val IPV4_REGEX = Regex("""(?<![:\da-fA-F])(?:\d{1,3}\.){3}\d{1,3}(?![:\da-fA-F])""")
        private val IPV6_REGEX = Regex("""(?i)(?:[0-9a-f]{1,4}:){2,7}[0-9a-f:]{0,4}""")

        private fun defaultTunnelClient(): OkHttpClient = MihomoLocalProxy.clientBuilder()
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(4, TimeUnit.SECONDS)
            .callTimeout(5, TimeUnit.SECONDS)
            .build()


        internal fun shouldReuseExitIdentity(
            nowMs: Long,
            cachedAtMs: Long,
            routeKey: String,
            cachedRouteKey: String?,
            cached: ExitIdentity,
        ): Boolean =
            routeKey == cachedRouteKey &&
                nowMs - cachedAtMs in 0 until EXIT_CACHE_MS &&
                (cached.ipv4 != null || cached.ipv6 != null)

        internal fun parseExitIdentity(
            ipv4Body: String?,
            ipv6Body: String?,
            geoBody: String?,
            json: Json = Json { ignoreUnknownKeys = true; isLenient = true },
        ): ExitIdentity {
            val ipv4 = findJsonValue(ipv4Body, json, "ip", "address", "ipv4")
                ?.takeIf { IPV4_REGEX.matches(it) }
                ?: ipv4Body?.let { IPV4_REGEX.find(it)?.value }
            val ipv6 = findJsonValue(ipv6Body, json, "ip", "address", "ipv6")
                ?.takeIf { IPV6_REGEX.matches(it) }
                ?: ipv6Body?.let { IPV6_REGEX.find(it)?.value }
                ?: findJsonValue(geoBody, json, "ip", "address", "ipv6")
                    ?.takeIf { IPV6_REGEX.matches(it) }
            val countryValue = findJsonValue(geoBody, json, "country")
            val countryCode = findJsonValue(
                geoBody,
                json,
                "country_code", "countryCode", "country_code2", "loc",
            ) ?: countryValue?.takeIf { it.length == 2 }
            return ExitIdentity(
                ipv4 = ipv4,
                ipv6 = ipv6,
                countryCode = countryCode,
                country = findJsonValue(geoBody, json, "country_name")
                    ?: countryValue?.takeUnless { it.length == 2 },
                region = findJsonValue(geoBody, json, "region", "regionName", "province"),
                city = findJsonValue(geoBody, json, "city"),
            )
        }

        private fun findJsonValue(
            body: String?,
            json: Json,
            vararg keys: String,
        ): String? {
            if (body.isNullOrBlank()) return null
            val keySet = keys.toSet()
            val root = runCatching { json.parseToJsonElement(body) }.getOrNull()
            if (root != null) return findValue(root, keySet)
            return body.lineSequence().firstNotNullOfOrNull { line ->
                val key = line.substringBefore('=', missingDelimiterValue = "").trim()
                val value = line.substringAfter('=', missingDelimiterValue = "").trim()
                value.takeIf { key in keySet && it.isNotEmpty() }
            }
        }

        private fun findValue(element: JsonElement, keys: Set<String>): String? = when (element) {
            is JsonObject -> {
                element.entries.firstNotNullOfOrNull { (key, value) ->
                    if (key in keys && value is JsonPrimitive && value.isString) {
                        value.content
                    } else {
                        null
                    }
                } ?: element.values.firstNotNullOfOrNull { findValue(it, keys) }
            }
            is JsonArray -> element.firstNotNullOfOrNull { findValue(it, keys) }
            else -> null
        }
    }
}
