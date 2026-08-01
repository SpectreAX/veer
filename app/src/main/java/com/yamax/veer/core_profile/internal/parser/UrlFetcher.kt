package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.SubscriptionUsageParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.brotli.BrotliInterceptor
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.TimeUnit

internal object UrlFetcher {

    private val baseClient = OkHttpClient.Builder()
        .connectTimeout(SubscriptionHttpConfig.CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
        .readTimeout(SubscriptionHttpConfig.READ_TIMEOUT_S, TimeUnit.SECONDS)
        // BrotliInterceptor adds `br` to Accept-Encoding and transparently decompresses responses.
        .addInterceptor(BrotliInterceptor)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    /**
     * Fetches a subscription URL, rotating through [SubscriptionHttpConfig.userAgents] on
     * retriable responses (4xx, empty body, HTML anti-bot pages).
     *
     * Cookies are shared across UA retries within one [fetch] call via [JavaNetCookieJar].
     *
     * Returns [SubscriptionFetchResult.AntiBotDetected] (not [SubscriptionFetchResult.Failed])
     * when every UA attempt ended in an anti-bot page — the caller can surface a meaningful
     * UI message instead of a generic "fetch failed".
     *
     * Privacy: only the host portion of the URL is ever logged. Token, query params,
     * Set-Cookie values are never emitted.
     */
    suspend fun fetch(url: String, debugCacheDir: File? = null): SubscriptionFetchResult =
        withContext(Dispatchers.IO) {
            val host = runCatching { java.net.URL(url).host }.getOrDefault("unknown")
            val uas  = SubscriptionHttpConfig.userAgents

            // Per-fetch CookieJar so cookies persist across UA retries for this call.
            val cookieJar = object : CookieJar {
                private val store = mutableMapOf<String, MutableList<Cookie>>()
                override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
                    store.getOrPut(url.host) { mutableListOf() }.addAll(cookies)
                }
                override fun loadForRequest(url: HttpUrl): List<Cookie> =
                    store[url.host] ?: emptyList()
            }
            val client = baseClient.newBuilder().cookieJar(cookieJar).build()

            var lastAntiBot: SubscriptionFetchResult.AntiBotDetected? = null
            var lastError   = "all UA attempts exhausted"

            for ((index, ua) in uas.withIndex()) {
                val attempt = index + 1
                VeerLog.profile("subscription fetch host=$host attempt=$attempt/${uas.size} ua=\"$ua\"")

                when (val r = tryOnce(client, url, ua, host, attempt, uas.size, debugCacheDir)) {
                    is AttemptResult.Success -> return@withContext r.result
                    is AttemptResult.AntiBot -> { lastAntiBot = r.result; lastError = r.result.category.displayName() }
                    is AttemptResult.Retry   -> { lastError = r.reason }
                    is AttemptResult.Fatal   -> return@withContext SubscriptionFetchResult.Failed(r.reason)
                }
            }

            if (lastAntiBot != null) {
                VeerLog.profile(
                    "subscription fetch host=$host all ${uas.size} UA(s) returned anti-bot: ${lastAntiBot.category.displayName()}",
                    VeerLog.Level.ERROR,
                )
                return@withContext lastAntiBot
            }

            VeerLog.profile(
                "subscription fetch host=$host all ${uas.size} UA(s) failed: $lastError",
                VeerLog.Level.ERROR,
            )
            SubscriptionFetchResult.Failed(lastError)
        }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    private sealed class AttemptResult {
        data class Success(val result: SubscriptionFetchResult.Success) : AttemptResult()
        data class AntiBot(val result: SubscriptionFetchResult.AntiBotDetected) : AttemptResult()
        data class Retry(val reason: String) : AttemptResult()
        data class Fatal(val reason: String) : AttemptResult()
    }

    private data class RedirectInfo(
        val count: Int,
        val trace: List<String>,
        val finalHost: String,
    )

    private fun tryOnce(
        client: OkHttpClient,
        url: String,
        ua: String,
        host: String,
        attempt: Int,
        total: Int,
        debugCacheDir: File?,
    ): AttemptResult {
        val request = try {
            Request.Builder()
                .url(url)
                .header("User-Agent", ua)
                .apply { SubscriptionHttpConfig.additionalHeaders.forEach { (k, v) -> header(k, v) } }
                .build()
        } catch (e: IllegalArgumentException) {
            return AttemptResult.Fatal("invalid URL: ${e.message}")
        }

        return try {
            client.newCall(request).execute().use { response ->
                val redirectInfo = buildRedirectInfo(response, host)
                logRedirectChain(response)
                logTlsInfo(response, host, attempt)

                val code      = response.code
                val finalHost = redirectInfo.finalHost

                if (code in SubscriptionHttpConfig.retryStatusCodes) {
                    logResponseDiagnostics(response, code, bodyPreview = null, category = null)
                    VeerLog.profile(
                        "subscription fetch host=$host attempt=$attempt HTTP $code — retry with next UA",
                        VeerLog.Level.WARN,
                    )
                    return@use AttemptResult.Retry("HTTP $code")
                }

                if (!response.isSuccessful) {
                    val reason = "HTTP $code: ${response.message}"
                    VeerLog.profile(
                        "subscription fetch host=$host attempt=$attempt $reason (non-retriable)",
                        VeerLog.Level.ERROR,
                    )
                    return@use AttemptResult.Fatal(reason)
                }

                val responseBody = response.body
                val declaredLength = responseBody?.contentLength() ?: -1L
                if (declaredLength > ProfileImportPolicy.MAX_PROFILE_BYTES) {
                    return@use AttemptResult.Fatal("response exceeds the 10 MiB profile limit")
                }
                val bytes = responseBody?.byteStream()?.readBytesLimited(ProfileImportPolicy.MAX_PROFILE_BYTES)
                if (bytes == null || bytes.isEmpty()) {
                    VeerLog.profile(
                        "subscription fetch host=$host attempt=$attempt empty body — retry with next UA",
                        VeerLog.Level.WARN,
                    )
                    return@use AttemptResult.Retry("empty response body")
                }

                val contentType = response.header("Content-Type") ?: ""
                val body        = String(bytes, Charsets.UTF_8)
                val antiBotReason = detectAntiBot(contentType, body)

                if (antiBotReason != null) {
                    val category = classifyHtml(code, body)
                    logResponseDiagnostics(response, code, bodyPreview = body, category = category)
                    saveDebugHtml(body, finalHost, debugCacheDir)
                    VeerLog.profile(
                        "subscription fetch host=$host attempt=$attempt" +
                            " anti-bot=$antiBotReason class=$category — retry with next UA",
                        VeerLog.Level.WARN,
                    )
                    return@use AttemptResult.AntiBot(
                        SubscriptionFetchResult.AntiBotDetected(
                            category      = category,
                            statusCode    = code,
                            finalHost     = finalHost,
                            redirectCount = redirectInfo.count,
                            redirectTrace = redirectInfo.trace,
                        )
                    )
                }

                VeerLog.profile(
                    "subscription fetch host=$host attempt=$attempt HTTP $code ok (${bytes.size} bytes)" +
                        if (redirectInfo.count > 0) " redirects=${redirectInfo.count} finalHost=$finalHost" else "",
                )
                AttemptResult.Success(
                    SubscriptionFetchResult.Success(
                        bytes         = bytes,
                        finalHost     = finalHost,
                        redirectCount = redirectInfo.count,
                        subscriptionUsage = SubscriptionUsageParser.parse(
                            response.header("Subscription-Userinfo"),
                        ),
                    )
                )
            }
        } catch (e: Exception) {
            val msg = e.message ?: e.javaClass.simpleName
            VeerLog.profile(
                "subscription fetch host=$host attempt=$attempt network error: $msg",
                VeerLog.Level.ERROR,
            )
            AttemptResult.Fatal("network error: $msg")
        }
    }

    // -------------------------------------------------------------------------
    // Redirect chain
    // -------------------------------------------------------------------------

    private fun buildRedirectInfo(response: Response, originalHost: String): RedirectInfo {
        val chain = buildList {
            var prior = response.priorResponse
            while (prior != null) {
                add(prior)
                prior = prior.priorResponse
            }
        }.reversed()

        val trace = chain.map { r ->
            val fromHost = r.request.url.host
            val toHost   = r.header("Location")
                ?.let { runCatching { java.net.URL(it).host }.getOrDefault("?") }
                ?: response.request.url.host
            "HTTP ${r.code} $fromHost → $toHost"
        }

        return RedirectInfo(
            count     = chain.size,
            trace     = trace,
            finalHost = response.request.url.host,
        )
    }

    private fun logRedirectChain(response: Response) {
        val chain = buildList {
            var prior = response.priorResponse
            while (prior != null) {
                add(prior)
                prior = prior.priorResponse
            }
        }.reversed()
        if (chain.isEmpty()) return
        chain.forEach { r ->
            val fromHost = r.request.url.host
            val toHost   = r.header("Location")
                ?.let { runCatching { java.net.URL(it).host }.getOrDefault(it.take(64)) }
                ?: "-"
            VeerLog.profile(
                "subscription redirect HTTP ${r.code} host=$fromHost → host=$toHost",
                VeerLog.Level.WARN,
            )
        }
    }

    // -------------------------------------------------------------------------
    // TLS / protocol info
    // -------------------------------------------------------------------------

    private fun logTlsInfo(response: Response, host: String, attempt: Int) {
        val handshake = response.handshake ?: return
        VeerLog.profile(
            "subscription fetch host=$host attempt=$attempt" +
                " protocol=${response.protocol}" +
                " tls=${handshake.tlsVersion.javaName}" +
                " cipher=${handshake.cipherSuite.javaName}",
        )
    }

    // -------------------------------------------------------------------------
    // Response diagnostics
    // -------------------------------------------------------------------------

    private fun logResponseDiagnostics(
        response: Response,
        code: Int,
        bodyPreview: String?,
        category: HtmlCategory?,
    ) {
        val server       = response.header("Server") ?: "-"
        val locationHost = response.header("Location")
            ?.let { runCatching { java.net.URL(it).host }.getOrDefault(it.take(64)) }
            ?: "-"
        val cookieKeys = response.headers("Set-Cookie")
            .mapNotNull { it.substringBefore('=').trim().takeIf { k -> k.isNotBlank() } }
            .distinct()
            .joinToString(", ")
            .ifEmpty { "-" }

        VeerLog.profile(
            "[diag] HTTP $code | Server: $server" +
                " | Location→host: $locationHost" +
                " | Set-Cookie keys: $cookieKeys" +
                (if (category != null) " | class: $category" else ""),
            VeerLog.Level.WARN,
        )

        if (!bodyPreview.isNullOrEmpty()) {
            val capped     = bodyPreview.take(4096)
            val meaningful = capped.lines().filter { it.isNotBlank() }
            VeerLog.profile(
                "[diag] HTML body omitted for privacy:" +
                    " ${bodyPreview.length} chars, ${meaningful.size} non-blank lines in first ${capped.length} chars",
                VeerLog.Level.WARN,
            )
        }
    }

    // -------------------------------------------------------------------------
    // Debug HTML save
    // -------------------------------------------------------------------------

    private fun saveDebugHtml(body: String, host: String, cacheDir: File?) {
        cacheDir ?: return
        runCatching {
            val dir  = File(cacheDir, "subscription_debug").also { it.mkdirs() }
            val file = File(dir, "${host}_${System.currentTimeMillis()}.html")
            file.writeText(body, Charsets.UTF_8)
            VeerLog.profile("[diag] debug HTML saved → ${file.name}", VeerLog.Level.WARN)
        }.onFailure { t ->
            VeerLog.profile("[diag] failed to save debug HTML: ${t.message}", VeerLog.Level.WARN)
        }
    }

    // -------------------------------------------------------------------------
    // HTML classification
    // -------------------------------------------------------------------------

    private fun classifyHtml(code: Int, body: String): HtmlCategory {
        val lower = body.lowercase()

        if (lower.contains("just a moment") ||
            lower.contains("checking your browser") ||
            lower.contains("cf-browser-verification") ||
            lower.contains("challenge-form") ||
            (lower.contains("cloudflare") && lower.contains("ray id"))
        ) return HtmlCategory.CLOUDFLARE_CHALLENGE

        if (lower.contains("_0x") ||
            (lower.contains("window.location") && lower.contains("settimeout")) ||
            (lower.contains("<noscript>") && lower.contains("redirect") && lower.contains("javascript"))
        ) return HtmlCategory.JS_CHALLENGE

        if (lower.contains("access denied") ||
            lower.contains("403 forbidden") ||
            lower.contains("blocked by") ||
            (lower.contains("firewall") && lower.contains("request")) ||
            code == 403
        ) return HtmlCategory.WAF_BLOCK

        if ((lower.contains("input") && lower.contains("password") && lower.contains("login")) ||
            (lower.contains("sign in") && lower.contains("password")) ||
            lower.contains("forgot password") ||
            (lower.contains("email") && lower.contains("password") && lower.contains("submit"))
        ) return HtmlCategory.LOGIN_PAGE

        if (lower.contains("套餐") || lower.contains("流量") ||
            lower.contains("订阅") || lower.contains("机场") || lower.contains("节点") ||
            (lower.contains("register") && lower.contains("pricing")) ||
            (lower.contains("vpn") && lower.contains("plan"))
        ) return HtmlCategory.AIRPORT_HOMEPAGE

        return HtmlCategory.UNKNOWN_HTML
    }

    // -------------------------------------------------------------------------
    // Anti-bot detection (body-first)
    // -------------------------------------------------------------------------

    /**
     * Returns a human-readable reason if [body] looks like an anti-bot page or non-YAML payload;
     * null if the content passes all checks and should be handed to the parser.
     *
     * Body content is checked FIRST. Many providers serve real YAML with Content-Type: text/html —
     * rejecting on content-type alone would be wrong.
     */
    private fun detectAntiBot(contentType: String, body: String): String? {
        // Priority 1: body has Clash YAML keywords → accept immediately regardless of Content-Type
        if (SubscriptionHttpConfig.clashYamlKeywords.any { body.contains(it) }) return null

        // Priority 2: body looks like base64-encoded subscription
        if (looksLikeBase64(body)) return null

        // From here the body is neither YAML nor encoded data — check for bad content
        if (contentType.contains("text/html", ignoreCase = true)) {
            return "text/html content-type (no Clash keywords)"
        }

        val trimmed = body.trimStart()
        if (trimmed.startsWith("<!") ||
            trimmed.take(6).equals("<html>", ignoreCase = true) ||
            trimmed.take(6).equals("<html ", ignoreCase = true)
        ) return "HTML response body"

        if (body.contains("Just a moment") ||
            body.contains("Checking your browser") ||
            (body.contains("cloudflare", ignoreCase = true) && body.contains("challenge", ignoreCase = true))
        ) return "Cloudflare challenge page"

        if (body.length > 2048) {
            val lower = body.lowercase()
            if (lower.contains("<html") && lower.contains("</html>")) {
                return "large HTML document (${body.length} bytes)"
            }
        }

        return null
    }

    private fun looksLikeBase64(text: String): Boolean {
        val t = text.trim()
        if (t.length < 20) return false
        val eligible = t.count {
            it.isLetterOrDigit() || it == '+' || it == '/' || it == '=' ||
                it == '-' || it == '_' || it == '\n' || it == '\r'
        }
        return eligible.toDouble() / t.length > 0.95
    }

    private fun InputStream.readBytesLimited(maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            total += count
            check(total <= maxBytes) { "response exceeds the 10 MiB profile limit" }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
