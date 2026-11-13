package com.yamax.veer.core_mihomo

import com.yamax.veer.core_profile.SubscriptionMetadata
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.ipc.CoreStateClient
import com.yamax.veer.core_mihomo.ipc.ProcessRole
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.File
import java.io.IOException
import java.net.Proxy
import java.util.concurrent.TimeUnit
import veercore.Veercore

/**
 * Single funnel for every call into the Mihomo local REST API.
 *
 * Callers — including the AI controller and any future UI — interact with
 * this class and never see OkHttp or the app-private Unix socket path. The
 * HTTP URL is only a virtual authority: production requests never open TCP.
 *
 * Thread-safety: all suspend functions hop to `Dispatchers.IO` internally
 * and the underlying OkHttpClient is safe for concurrent use.
 */
class MihomoRepository internal constructor(
    private val controllerHost: String = DEFAULT_HOST,
    private val controllerPort: Int = DEFAULT_PORT,
    private val secret: String = ControllerSecretStore.getOrCreate(),
    private val client: OkHttpClient = defaultClient(),
) {

    init {
        require(secret.isNotBlank()) { "Mihomo Controller credential is required" }
    }

    constructor() : this(
        DEFAULT_HOST,
        DEFAULT_PORT,
        ControllerSecretStore.getOrCreate(),
        unixClient(ControllerSecretStore.socketPath()),
    )

    private val baseUrl: String = "http://$controllerHost:$controllerPort"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** Probe used by health checks; null if the controller isn't reachable. */
    suspend fun version(): String? = withContext(Dispatchers.IO) {
        try {
            client.newCall(get("/version")).execute().use { res ->
                if (res.isSuccessful) res.body?.string() else null
            }
        } catch (_: IOException) {
            null
        }
    }

    /** Short controller probe for the startup readiness gate. */
    suspend fun controllerReady(): Boolean = withContext(Dispatchers.IO) {
        val readinessClient = client.newBuilder()
            .connectTimeout(READINESS_PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .readTimeout(READINESS_PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .writeTimeout(READINESS_PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .callTimeout(READINESS_PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .build()
        runCatching {
            readinessClient.newCall(get("/version")).execute().use { response ->
                response.isSuccessful && !response.body?.string().isNullOrBlank()
            }
        }.getOrDefault(false)
    }

    /** Current Mihomo routing mode (`rule`, `global`, or `direct`). */
    suspend fun runtimeMode(): String? = withContext(Dispatchers.IO) {
        try {
            client.newCall(get("/configs")).execute().use { response ->
                if (!response.isSuccessful) return@withContext null
                json.parseToJsonElement(response.body?.string().orEmpty())
                    .jsonObject["mode"]
                    ?.jsonPrimitive
                    ?.contentOrNull
                    ?.lowercase()
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Asks Mihomo to re-read the AI override rule provider. Returns a typed
     * result so callers can log the HTTP status without dealing with OkHttp.
     */
    suspend fun reloadAiProvider(
        name: String = AI_OVERRIDE_PROVIDER,
    ): ReloadResult = withContext(Dispatchers.IO) {
        val req = baseRequest("/providers/rules/$name")
            .put(EMPTY_JSON.toRequestBody(JSON_MEDIA))
            .build()
        try {
            client.newCall(req).execute().use { res ->
                ReloadResult(success = res.isSuccessful, status = res.code, message = res.message)
            }
        } catch (e: IOException) {
            ReloadResult(success = false, status = -1, message = e.message ?: "io error")
        }
    }

    /** Swaps only the live rule table, preserving the Android-owned TUN fd. */
    suspend fun reloadRules(configFile: File): ReloadResult = withContext(Dispatchers.IO) {
        if (CoreStateClient.isAvailable() && !ProcessRole.isCoreProcess()) {
            val remote = CoreStateClient.reloadRules(configFile)
                ?: return@withContext ReloadResult(
                    success = false,
                    status = -1,
                    message = "Veercore IPC unavailable",
                )
            if (remote.success) {
                CoreRuntimeEvents.publish(CoreRuntimeMutation.RULES_RELOADED)
            }
            return@withContext ReloadResult(
                success = remote.success,
                status = remote.status,
                message = remote.message,
            )
        }
        try {
            VeercoreNativeExecutor.call {
                Veercore.reloadRules(configFile.parentFile!!.absolutePath, configFile.name)
            }
            CoreRuntimeEvents.publish(CoreRuntimeMutation.RULES_RELOADED)
            ReloadResult(success = true, status = 0, message = "native rules reload complete")
        } catch (e: Exception) {
            ReloadResult(success = false, status = -1, message = e.message ?: "native reload error")
        }
    }

    /**
     * Returns every policy that can be used as a rule target: proxy groups,
     * concrete proxy nodes, and Mihomo's built-in policies. Supplying groups
     * alone makes requests such as "走日本节点" impossible to resolve because
     * subscriptions commonly expose Japan only as individual node names.
     */
    suspend fun routingTargets(): List<String> = withContext(Dispatchers.IO) {
        val snapshot = fetchRoutingSnapshot()
        (snapshot.proxies.values
            .filterNot { it.type == "Compatible" || it.name == "COMPATIBLE" }
            .map { it.name } + DEFAULT_TARGETS).distinct()
    }

    /**
     * One consistent view of Mihomo's groups, current selections, members and
     * most recent delay samples. The AI sees only this real runtime state; it
     * never invents a group or node from examples in the system prompt.
     */
    suspend fun routingSnapshot(): RoutingSnapshot = withContext(Dispatchers.IO) {
        fetchRoutingSnapshot()
    }

    /**
     * Lightweight current route for the home dashboard.
     *
     * Unlike [routingSnapshot], this does not marshal the entire proxy graph,
     * member arrays and delay histories through localhost JSON.
     */
    suspend fun dashboardRoutingSnapshot(defaultPolicy: String?): DashboardRoutingSnapshot? =
        withContext(Dispatchers.IO) {
            CoreStateClient.dashboardRoutingSnapshot(defaultPolicy)?.let { stats ->
                return@withContext DashboardRoutingSnapshot(
                    coreRunning = stats.coreRunning,
                    mode = stats.mode,
                    policy = stats.policy,
                    selectedNode = stats.selectedNode,
                    nodeDelayMs = stats.nodeDelayMs,
                )
            }
            if (CoreStateClient.isAvailable() && !ProcessRole.isCoreProcess()) {
                return@withContext null
            }
            runCatching {
                val stats = VeercoreNativeExecutor.call {
                    Veercore.getDashboardRoutingStats(defaultPolicy.orEmpty())
                }
                DashboardRoutingSnapshot(
                    coreRunning = stats.coreRunning,
                    mode = stats.mode,
                    policy = stats.policy.takeIf(String::isNotBlank),
                    selectedNode = stats.selectedNode.takeIf(String::isNotBlank),
                    nodeDelayMs = stats.nodeDelayMs.takeIf { it >= 0 },
                )
            }.getOrNull()
        }

    /**
     * Returns the current proxy selection for every Selector-type group.
     * Key = group name, value = currently-selected proxy name.
     * Returns empty map if the controller is not reachable.
     */
    suspend fun proxySelections(): Map<String, String> = withContext(Dispatchers.IO) {
        try {
            client.newCall(get("/proxies")).execute().use { res ->
                if (!res.isSuccessful) return@withContext emptyMap()
                val body = res.body?.string().orEmpty()
                val tree = json.parseToJsonElement(body).jsonObject["proxies"]?.jsonObject
                    ?: return@withContext emptyMap()
                buildMap {
                    tree.entries.forEach { (name, value) ->
                        val obj = value as? JsonObject ?: return@forEach
                        if (obj["type"]?.jsonPrimitive?.contentOrNull == "Selector") {
                            val now = obj["now"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                            put(name, now)
                        }
                    }
                }
            }
        } catch (_: IOException) {
            emptyMap()
        }
    }

    /**
     * Cumulative payload counters for the current Mihomo runtime session.
     *
     * The normal path reads Mihomo's statistic manager through the in-process
     * gomobile bridge. The REST fallback keeps developer builds usable if an
     * older AAR is temporarily paired with newer Kotlin sources.
     */
    suspend fun trafficSnapshot(): TrafficSnapshot? = withContext(Dispatchers.IO) {
        nativeTrafficSnapshot()?.let { return@withContext it }
        restTrafficSnapshot()
    }

    private fun nativeTrafficSnapshot(): TrafficSnapshot? = runCatching {
        CoreStateClient.trafficSnapshot()?.let { stats ->
            return@runCatching TrafficSnapshot(
                uploadTotal = stats.uploadTotal,
                downloadTotal = stats.downloadTotal,
                activeConnections = stats.activeConnections,
            )
        }
        if (CoreStateClient.isAvailable() && !ProcessRole.isCoreProcess()) {
            return@runCatching null
        }
        val stats = VeercoreNativeExecutor.call { Veercore.getTrafficStats() }
        TrafficSnapshot(
            uploadTotal = stats.uploadTotal,
            downloadTotal = stats.downloadTotal,
            activeConnections = stats.activeConnections,
        )
    }.getOrNull()

    private fun restTrafficSnapshot(): TrafficSnapshot? {
        try {
            client.newCall(get("/connections")).execute().use { res ->
                if (!res.isSuccessful) return null
                val root = json.parseToJsonElement(res.body?.string().orEmpty()).jsonObject
                return TrafficSnapshot(
                    uploadTotal = root["uploadTotal"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                        ?: 0L,
                    downloadTotal = root["downloadTotal"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                        ?: 0L,
                    activeConnections = (root["connections"] as? JsonArray)?.size ?: 0,
                )
            }
        } catch (_: Exception) {
            return null
        }
    }

    suspend fun getConnectionDetails(): Result<List<ConnectionInfo>> = withContext(Dispatchers.IO) {
        try {
            client.newCall(get("/connections")).execute().use { res ->
                if (!res.isSuccessful) {
                    return@withContext Result.failure(
                        IOException("controller returned HTTP ${res.code}"),
                    )
                }
                val body = res.body?.string().orEmpty()
                val root = json.parseToJsonElement(body).jsonObject
                Result.success((root["connections"] as? JsonArray).orEmpty().mapNotNull { value ->
                    val conn = value as? JsonObject ?: return@mapNotNull null
                    val metadata = conn["metadata"] as? JsonObject
                    ConnectionInfo(
                        id = conn["id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        host = metadata?.get("host")?.jsonPrimitive?.contentOrNull.orEmpty(),
                        destinationIP = metadata?.get("destinationIP")?.jsonPrimitive?.contentOrNull.orEmpty(),
                        network = metadata?.get("network")?.jsonPrimitive?.contentOrNull.orEmpty(),
                        type = metadata?.get("type")?.jsonPrimitive?.contentOrNull.orEmpty(),
                        chains = (conn["chains"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty(),
                        rule = conn["rule"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        rulePayload = conn["rulePayload"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        download = conn["download"]?.jsonPrimitive?.longOrNull ?: 0L,
                        upload = conn["upload"]?.jsonPrimitive?.longOrNull ?: 0L,
                        start = conn["start"]?.jsonPrimitive?.contentOrNull.orEmpty()
                    )
                })
            }
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    suspend fun closeConnection(id: String): Boolean = withContext(Dispatchers.IO) {
        if (id.isBlank()) return@withContext false
        try {
            val url = baseUrl.toHttpUrl()
                .newBuilder()
                .addPathSegment("connections")
                .addPathSegment(id)
                .build()
            val request = Request.Builder()
                .url(url)
                .apply { if (secret.isNotEmpty()) header("Authorization", "Bearer $secret") }
                .delete()
                .build()
            client.newCall(request).execute().use { it.isSuccessful }
        } catch (_: Exception) {
            false
        }
    }

    suspend fun closeAllConnections(): Boolean = withContext(Dispatchers.IO) {
        try {
            client.newCall(delete("/connections")).execute().use { it.isSuccessful }
        } catch (_: Exception) {
            false
        }
    }

    /** Ordered runtime rule table exposed by Mihomo's controller. */
    suspend fun rulesSnapshot(): List<RuleState> = withContext(Dispatchers.IO) {
        try {
            client.newCall(get("/rules")).execute().use { res ->
                if (!res.isSuccessful) return@withContext emptyList()
                val root = json.parseToJsonElement(res.body?.string().orEmpty()).jsonObject
                (root["rules"] as? JsonArray).orEmpty().mapNotNull { value ->
                    val rule = value as? JsonObject ?: return@mapNotNull null
                    RuleState(
                        index = rule["index"]?.jsonPrimitive?.intOrNull ?: return@mapNotNull null,
                        type = rule["type"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        payload = rule["payload"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        proxy = rule["proxy"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** Resolves [host] through Mihomo's own DNS pipeline, including fake-IP rules. */
    suspend fun dnsQuery(host: String): DnsQueryResult = withContext(Dispatchers.IO) {
        val encoded = java.net.URLEncoder.encode(host, "UTF-8").replace("+", "%20")
        try {
            client.newCall(get("/dns/query?name=$encoded&type=A")).execute().use { res ->
                val body = res.body?.string().orEmpty()
                if (!res.isSuccessful) {
                    return@withContext DnsQueryResult(false, emptyList(), "HTTP ${res.code}")
                }
                val root = json.parseToJsonElement(body).jsonObject
                val status = root["Status"]?.jsonPrimitive?.intOrNull
                val addresses = (root["Answer"] as? JsonArray).orEmpty().mapNotNull { value ->
                    val answer = value as? JsonObject ?: return@mapNotNull null
                    answer["data"]?.jsonPrimitive?.contentOrNull
                }
                DnsQueryResult(
                    success = status == 0 && addresses.isNotEmpty(),
                    addresses = addresses,
                    message = if (status == 0) "resolved" else "DNS status=$status",
                )
            }
        } catch (e: Exception) {
            DnsQueryResult(false, emptyList(), e.message ?: "DNS query failed")
        }
    }

    /**
     * Switches the active proxy inside [groupName] to [proxyName].
     * Returns true on HTTP 204, false if the controller is unreachable or returns an error.
     */
    suspend fun selectProxy(groupName: String, proxyName: String): Boolean =
        withContext(Dispatchers.IO) {
            val encoded = java.net.URLEncoder.encode(groupName, "UTF-8").replace("+", "%20")
            val bodyText = buildJsonObject { put("name", proxyName) }.toString()
            val req = baseRequest("/proxies/$encoded")
                .put(bodyText.toRequestBody(JSON_MEDIA))
                .build()
            try {
                client.newCall(req).execute().use {
                    it.isSuccessful.also { success ->
                        if (success) {
                            runCatching { ProfileSelectionStore.recordActive(groupName, proxyName) }
                                .onFailure {
                                    VeerLog.profile(
                                        "failed to persist proxy selection: ${it.message}",
                                        VeerLog.Level.WARN,
                                    )
                                }
                            CoreRuntimeEvents.publish(
                                CoreRuntimeMutation.ROUTE_SELECTION_CHANGED,
                            )
                        }
                    }
                }
            } catch (_: IOException) {
                false
            }
        }

    /**
     * Finds the fastest replacement node for [groupName] using fresh Mihomo
     * delay probes, not just historical `/proxies` samples. Unknown/stale
     * delay history is useful for display, but user commands such as
     * "节点太卡了换一个" need current evidence before mutating a selector.
     */
    suspend fun lowestLatencyCandidate(
        groupName: String,
        snapshot: RoutingSnapshot? = null,
        timeoutMs: Int = DEFAULT_DELAY_TIMEOUT_MS,
        probeUrl: String = DEFAULT_DELAY_PROBE_URL,
    ): ProxyState? = withContext(Dispatchers.IO) {
        val baseSnapshot = snapshot ?: fetchRoutingSnapshot()
        val candidates = baseSnapshot.switchCandidates(groupName)
        if (candidates.isEmpty()) return@withContext null

        val semaphore = Semaphore(DEFAULT_DELAY_PROBE_CONCURRENCY)
        val measured = coroutineScope {
            candidates.map { candidate ->
                async {
                    semaphore.withPermit {
                        probeDelay(candidate.name, timeoutMs, probeUrl)
                            ?.let { candidate.copy(delayMs = it) }
                    }
                }
            }.awaitAll().filterNotNull()
        }
        measured.minByOrNull { it.delayMs ?: Int.MAX_VALUE }
            ?: baseSnapshot.latencyFallbackCandidate(groupName)
    }

    /** Measures one concrete proxy through Mihomo's controller delay endpoint. */
    suspend fun probeProxyDelay(
        proxyName: String,
        timeoutMs: Int = DEFAULT_DELAY_TIMEOUT_MS,
        probeUrl: String = DEFAULT_DELAY_PROBE_URL,
    ): Int? = withContext(Dispatchers.IO) {
        probeDelay(proxyName, timeoutMs, probeUrl)
    }

    private fun probeDelay(proxyName: String, timeoutMs: Int, probeUrl: String): Int? {
        val encodedName = java.net.URLEncoder.encode(proxyName, "UTF-8").replace("+", "%20")
        val encodedUrl = java.net.URLEncoder.encode(probeUrl, "UTF-8")
        val req = baseRequest("/proxies/$encodedName/delay?timeout=$timeoutMs&url=$encodedUrl")
            .get()
            .build()
        return try {
            client.newCall(req).execute().use { res ->
                if (!res.isSuccessful) return null
                val body = res.body?.string().orEmpty()
                json.parseToJsonElement(body).jsonObject["delay"]
                    ?.jsonPrimitive
                    ?.intOrNull
                    ?.takeIf { it > 0 }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun fetchRoutingSnapshot(): RoutingSnapshot {
        return try {
            client.newCall(get("/proxies")).execute().use { res ->
                if (!res.isSuccessful) return RoutingSnapshot.EMPTY
                val body = res.body?.string().orEmpty()
                val tree = json.parseToJsonElement(body).jsonObject["proxies"]?.jsonObject
                    ?: return RoutingSnapshot.EMPTY
                val proxies = tree.entries.mapNotNull { (name, value) ->
                    val obj = value as? JsonObject ?: return@mapNotNull null
                    val type = obj["type"]?.jsonPrimitive?.contentOrNull.orEmpty()
                    val members = (obj["all"] as? JsonArray)
                        ?.mapNotNull { it.jsonPrimitive.contentOrNull }
                        .orEmpty()
                    val delayMs = (obj["history"] as? JsonArray)
                        ?.lastOrNull()
                        ?.let { it as? JsonObject }
                        ?.get("delay")
                        ?.jsonPrimitive
                        ?.intOrNull
                        ?.takeIf { it > 0 }
                    ProxyState(
                        name = name,
                        type = type,
                        now = obj["now"]?.jsonPrimitive?.contentOrNull,
                        members = members,
                        delayMs = delayMs,
                        alive = obj["alive"]?.jsonPrimitive?.booleanOrNull,
                    )
                }.associateBy { it.name }
                RoutingSnapshot(proxies)
            }
        } catch (_: IOException) {
            RoutingSnapshot.EMPTY
        }
    }

    private fun get(path: String): Request = baseRequest(path).get().build()
    private fun delete(path: String): Request = baseRequest(path).delete().build()

    private fun baseRequest(path: String): Request.Builder = Request.Builder()
        .url(baseUrl + path)
        .apply { if (secret.isNotEmpty()) header("Authorization", "Bearer $secret") }

    data class ReloadResult(val success: Boolean, val status: Int, val message: String)

    data class ConnectionInfo(
        val id: String,
        val host: String,
        val destinationIP: String,
        val network: String,
        val type: String,
        val chains: List<String>,
        val rule: String,
        val rulePayload: String,
        val download: Long,
        val upload: Long,
        val start: String,
    )

    data class TrafficSnapshot(
        val uploadTotal: Long,
        val downloadTotal: Long,
        val activeConnections: Int,
    )

    data class DashboardRoutingSnapshot(
        val coreRunning: Boolean,
        val mode: String,
        val policy: String?,
        val selectedNode: String?,
        val nodeDelayMs: Int?,
    )

    data class RuleState(
        val index: Int,
        val type: String,
        val payload: String,
        val proxy: String,
    )

    data class DnsQueryResult(
        val success: Boolean,
        val addresses: List<String>,
        val message: String,
    )

    data class ProxyState(
        val name: String,
        val type: String,
        val now: String?,
        val members: List<String>,
        val delayMs: Int?,
        val alive: Boolean? = null,
    ) {
        val regionCode: String? get() = RoutingSnapshot.regionTokenForName(name)
    }

    data class RoutingSnapshot(val proxies: Map<String, ProxyState>) {
        val selectorGroups: List<ProxyState>
            get() = proxies.values.filter { it.type == "Selector" }

        fun lowestLatencyCandidate(groupName: String): ProxyState? {
            return switchCandidates(groupName)
                .filter { it.isKnownUsable() }
                .filter { it.delayMs != null }
                .minByOrNull { it.delayMs!! }
        }

        /**
         * Chooses a conservative fallback when fresh delay probes all fail.
         *
         * If the selector is already delegated to URLTest/Fallback/LoadBalance,
         * keep that automatic policy instead of oscillating to another group on
         * every repeated "换个快的" command. Otherwise prefer URLTest, then a
         * usable historical sample.
         */
        fun latencyFallbackCandidate(groupName: String): ProxyState? {
            val group = proxies[groupName]?.takeIf { it.type == "Selector" } ?: return null
            if (isUsingAutomaticSelector(groupName)) {
                val current = group.now?.let(proxies::get)
                if (current != null && isOperationalAutomaticPolicy(current)) return current
            }
            return automaticLatencyCandidate(groupName) ?: lowestLatencyCandidate(groupName)
        }

        fun automaticLatencyCandidate(groupName: String): ProxyState? {
            val group = proxies[groupName]?.takeIf { it.type == "Selector" } ?: return null
            val currentChain = currentChain(group)
            return group.members.asSequence()
                .mapNotNull(proxies::get)
                .filter { it.name !in currentChain }
                .filter { it.type in AUTOMATIC_GROUP_TYPES || "自动选择" in it.name }
                .filter { isUsableNodeName(it.name) }
                .filter(::isOperationalAutomaticPolicy)
                .filter { it.alive != false }
                .minByOrNull { AUTOMATIC_GROUP_PRIORITY[it.type] ?: 99 }
        }

        fun isUsingAutomaticSelector(groupName: String): Boolean {
            val group = proxies[groupName]?.takeIf { it.type == "Selector" } ?: return false
            val current = group.now ?: return false
            val currentState = proxies[current] ?: return false
            return currentState.type in AUTOMATIC_GROUP_TYPES || "自动选择" in currentState.name
        }

        fun availableEquivalent(policyName: String): ProxyState? {
            val selected = proxies[policyName] ?: return null
            if (selected.members.isNotEmpty() || selected.type in NON_PROXY_TYPES) return selected
            if (selected.isKnownUsable()) return selected

            val region = selected.regionToken() ?: return null
            return proxies.values.asSequence()
                .filter { it.members.isEmpty() }
                .filter { it.type !in NON_PROXY_TYPES }
                .filter { isUsableNodeName(it.name) }
                .filter { it.regionToken() == region }
                .filter { it.isKnownUsable() }
                .minWithOrNull(compareBy<ProxyState> { it.delayMs ?: Int.MAX_VALUE }.thenBy { it.name })
        }

        fun isKnownUnavailable(policyName: String): Boolean {
            val selected = proxies[policyName] ?: return false
            return selected.members.isEmpty() && selected.type !in NON_PROXY_TYPES && !selected.isKnownUsable()
        }

        /** Resolves a group selection chain to its concrete leaf node. */
        fun resolvedLeaf(policyName: String): ProxyState? {
            var current = proxies[policyName] ?: return null
            val visited = mutableSetOf<String>()
            while (current.members.isNotEmpty()) {
                if (!visited.add(current.name)) return null
                val next = current.now ?: return null
                current = proxies[next] ?: return null
            }
            return current
        }

        fun switchCandidates(groupName: String): List<ProxyState> {
            val group = proxies[groupName]?.takeIf { it.type == "Selector" } ?: return emptyList()
            val currentChain = currentChain(group)
            return group.members.asSequence()
                .mapNotNull(proxies::get)
                .filter { it.members.isEmpty() }
                .filter { it.name !in currentChain }
                .filter { it.type !in NON_PROXY_TYPES }
                .filter { isUsableNodeName(it.name) }
                .filter { it.alive != false }
                .toList()
        }

        private fun currentChain(group: ProxyState): Set<String> = buildSet {
            var name = group.now
            while (name != null && add(name)) name = proxies[name]?.now
        }

        private fun isOperationalAutomaticPolicy(policy: ProxyState): Boolean {
            var current: ProxyState? = policy
            val visited = mutableSetOf<String>()
            while (current != null && current.members.isNotEmpty()) {
                if (!visited.add(current.name)) return false
                val nextName = current.now ?: return false
                if (!isUsableNodeName(nextName)) return false
                current = proxies[nextName] ?: return false
            }
            return current != null && isUsableNodeName(current.name)
        }

        companion object {
            val EMPTY = RoutingSnapshot(emptyMap())
            private val NON_PROXY_TYPES = setOf(
                "Compatible", "Direct", "Pass", "Reject", "RejectDrop",
            )
            private val AUTOMATIC_GROUP_TYPES = setOf("URLTest", "Fallback", "LoadBalance")
            private val AUTOMATIC_GROUP_PRIORITY = mapOf(
                "URLTest" to 0,
                "LoadBalance" to 1,
                "Fallback" to 2,
            )
            private fun isUsableNodeName(name: String): Boolean =
                !SubscriptionMetadata.isLikelyMetadataName(name)

            private fun ProxyState.isKnownUsable(): Boolean =
                alive != false && delayMs != 65535

            internal fun regionTokenForName(name: String): String? {
                val normalized = name.lowercase()
                return REGION_ALIASES.entries.firstOrNull { (_, aliases) ->
                    aliases.any { alias ->
                        if (alias.length == 2 && alias.all(Char::isLetter)) {
                            Regex("""(^|[^a-z])${Regex.escape(alias)}([^a-z]|$)""")
                                .containsMatchIn(normalized)
                        } else {
                            normalized.contains(alias)
                        }
                    }
                }?.key
            }

            private fun ProxyState.regionToken(): String? = regionTokenForName(name)

            private val REGION_ALIASES = linkedMapOf(
                "HK" to listOf("香港", "🇭🇰", "hong kong", "hongkong", "hk"),
                "JP" to listOf("日本", "🇯🇵", "japan", "tokyo", "osaka", "jp"),
                "US" to listOf("美国", "美國", "🇺🇸", "united states", "america", "los angeles", "san jose", "us"),
                "SG" to listOf("新加坡", "狮城", "獅城", "🇸🇬", "singapore", "sg"),
                "TW" to listOf("台湾", "台灣", "🇹🇼", "taiwan", "taipei", "tw"),
                "MO" to listOf("澳门", "澳門", "🇲🇴", "macao", "macau", "mo"),
                "KR" to listOf("韩国", "韓國", "🇰🇷", "korea", "seoul", "kr"),
                "GB" to listOf("英国", "英國", "🇬🇧", "united kingdom", "london", "uk", "gb"),
                "DE" to listOf("德国", "德國", "🇩🇪", "germany", "frankfurt", "de"),
                "FR" to listOf("法国", "法國", "🇫🇷", "france", "paris", "fr"),
                "CA" to listOf("加拿大", "🇨🇦", "canada", "toronto", "ca"),
                "AU" to listOf("澳大利亚", "澳洲", "🇦🇺", "australia", "sydney", "au"),
                "IN" to listOf("印度", "🇮🇳", "india", "mumbai", "in"),
            )
        }
    }

    companion object {
        const val AI_OVERRIDE_PROVIDER = "ai_override_provider"

        private const val DEFAULT_HOST = "localhost"
        private const val DEFAULT_PORT = 80
        private const val DEFAULT_DELAY_TIMEOUT_MS = 2500
        private const val DEFAULT_DELAY_PROBE_CONCURRENCY = 4
        private const val DEFAULT_DELAY_PROBE_URL = "https://www.gstatic.com/generate_204"
        private const val READINESS_PROBE_TIMEOUT_MS = 200L

        private val JSON_MEDIA = "application/json".toMediaType()
        private const val EMPTY_JSON = "{}"
        private val DEFAULT_TARGETS = listOf("PROXY", "DIRECT", "REJECT")

        private fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .build()

        private fun unixClient(socketPath: String): OkHttpClient = OkHttpClient.Builder()
            .proxy(Proxy.NO_PROXY)
            .socketFactory(UnixControllerSocketFactory(socketPath))
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .build()

        // Process-wide singleton so the AI layer and any future caller share
        // one connection pool. Not a hard requirement — feel free to inject.
        @Volatile private var INSTANCE: MihomoRepository? = null
        fun get(): MihomoRepository =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: MihomoRepository().also { INSTANCE = it }
            }
    }
}
