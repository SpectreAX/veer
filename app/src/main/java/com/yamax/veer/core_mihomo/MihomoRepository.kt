package com.yamax.veer.core_mihomo

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Single funnel for every call into the Mihomo local REST API.
 *
 * Callers — including the AI controller and any future UI — interact with
 * this class and never see `127.0.0.1`, `9090`, OkHttp, or path strings.
 * That isolation matters because some Android ROMs (MIUI / HyperOS in
 * particular) clamp localhost traffic in ways that may force us to move the
 * controller (e.g. abstract Unix socket, in-process gRPC) without touching
 * the rest of the app.
 *
 * Thread-safety: all suspend functions hop to `Dispatchers.IO` internally
 * and the underlying OkHttpClient is safe for concurrent use.
 */
class MihomoRepository internal constructor(
    private val controllerHost: String = DEFAULT_HOST,
    private val controllerPort: Int = DEFAULT_PORT,
    private val secret: String = "",
    private val client: OkHttpClient = defaultClient(),
) {

    constructor() : this(DEFAULT_HOST, DEFAULT_PORT)

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

    /**
     * Returns the names of every user-selectable proxy group (Selector /
     * URLTest / Fallback / LoadBalance / Relay). Falls back to a built-in
     * default if the controller is silent so the LLM still has a non-empty
     * context list to work with.
     */
    suspend fun proxyGroups(): List<String> = withContext(Dispatchers.IO) {
        try {
            client.newCall(get("/proxies")).execute().use { res ->
                if (!res.isSuccessful) return@withContext DEFAULT_GROUPS
                val body = res.body?.string().orEmpty()
                val tree = json.parseToJsonElement(body).jsonObject["proxies"]?.jsonObject
                    ?: return@withContext DEFAULT_GROUPS
                val names = tree.entries.mapNotNull { entry ->
                    val type = (entry.value as? JsonObject)?.get("type")?.jsonPrimitive?.contentOrNull
                    if (type in SELECTABLE_TYPES) entry.key else null
                }
                if (names.isEmpty()) DEFAULT_GROUPS else names
            }
        } catch (_: IOException) {
            DEFAULT_GROUPS
        }
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
                client.newCall(req).execute().use { it.isSuccessful }
            } catch (_: IOException) {
                false
            }
        }

    private fun get(path: String): Request = baseRequest(path).get().build()

    private fun baseRequest(path: String): Request.Builder = Request.Builder()
        .url(baseUrl + path)
        .apply { if (secret.isNotEmpty()) header("Authorization", "Bearer $secret") }

    data class ReloadResult(val success: Boolean, val status: Int, val message: String)

    companion object {
        const val AI_OVERRIDE_PROVIDER = "ai_override_provider"

        private const val DEFAULT_HOST = "127.0.0.1"
        private const val DEFAULT_PORT = 9090

        private val JSON_MEDIA = "application/json".toMediaType()
        private const val EMPTY_JSON = "{}"
        private val SELECTABLE_TYPES = setOf("Selector", "URLTest", "Fallback", "LoadBalance", "Relay")
        private val DEFAULT_GROUPS = listOf("PROXY", "DIRECT", "REJECT")

        private fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
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
