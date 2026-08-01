package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_profile.ImportedProfile
import com.yamax.veer.core_profile.SubscriptionUsage
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

// ---------------------------------------------------------------------------
// Input types
// ---------------------------------------------------------------------------

internal sealed class ProfileInput {
    /** Raw YAML bytes from a local file. [fileName] is used for display/logging only. */
    data class YamlBytes(val bytes: ByteArray, val fileName: String) : ProfileInput()
    /** HTTPS subscription URL; fetched via OkHttp. */
    data class SubscriptionUrl(val url: String) : ProfileInput()
    /** Base64-encoded YAML (or sometimes a subscription list). */
    data class Base64Text(val encoded: String) : ProfileInput()
}

// ---------------------------------------------------------------------------
// Anti-bot HTML classification
// ---------------------------------------------------------------------------

internal enum class HtmlCategory {
    CLOUDFLARE_CHALLENGE,
    JS_CHALLENGE,
    WAF_BLOCK,
    LOGIN_PAGE,
    AIRPORT_HOMEPAGE,
    UNKNOWN_HTML;

    fun displayName(): String = when (this) {
        CLOUDFLARE_CHALLENGE -> "Cloudflare challenge"
        JS_CHALLENGE         -> "JS challenge / obfuscated redirect"
        WAF_BLOCK            -> "WAF / firewall block"
        LOGIN_PAGE           -> "Login / auth wall"
        AIRPORT_HOMEPAGE     -> "机场要求登录 / subscription homepage"
        UNKNOWN_HTML         -> "Unexpected HTML response"
    }
}

// ---------------------------------------------------------------------------
// Validation errors
// ---------------------------------------------------------------------------

internal sealed class ValidationError {
    data class MalformedYaml(val detail: String) : ValidationError()
    data class DuplicateProxy(val name: String) : ValidationError()
    data class InvalidPort(val proxyName: String, val port: Int) : ValidationError()
    data class UnsupportedProxyType(val proxyName: String, val type: String) : ValidationError()
    data class EmptyProxyGroup(val groupName: String) : ValidationError()
    data class MissingRequiredField(val proxyName: String, val field: String) : ValidationError()
    data class BrokenGroupReference(val groupName: String, val missingProxy: String) : ValidationError()
    object NoProxies : ValidationError()
    object NoProxyGroups : ValidationError()
    data class InvalidSubscriptionUrl(val detail: String) : ValidationError()
    data class ProfileTooLarge(val maxBytes: Int) : ValidationError()
    object RuntimeMustBeStopped : ValidationError()
    data class AntiBotBlock(
        val category: HtmlCategory,
        val statusCode: Int,
        val finalHost: String,
        val redirectCount: Int,
    ) : ValidationError()
}

internal fun ValidationError.message(): String = when (this) {
    is ValidationError.MalformedYaml          -> "Malformed YAML: $detail"
    is ValidationError.DuplicateProxy         -> "Duplicate proxy name: \"$name\""
    is ValidationError.InvalidPort            -> "Invalid port $port on proxy \"$proxyName\""
    is ValidationError.UnsupportedProxyType   -> "Unsupported proxy type \"$type\" on \"$proxyName\""
    is ValidationError.EmptyProxyGroup        -> "Proxy group \"$groupName\" has no proxies"
    is ValidationError.MissingRequiredField   -> "Proxy \"$proxyName\" missing required field: $field"
    is ValidationError.BrokenGroupReference   -> "Group \"$groupName\" references unknown proxy \"$missingProxy\""
    is ValidationError.NoProxies              -> "Profile contains no proxies"
    is ValidationError.NoProxyGroups          -> "Profile contains no proxy groups"
    is ValidationError.InvalidSubscriptionUrl -> "Invalid subscription URL: $detail"
    is ValidationError.ProfileTooLarge        -> "Profile exceeds the ${maxBytes / 1024 / 1024} MiB limit"
    is ValidationError.RuntimeMustBeStopped   -> "Stop the VPN before changing the active profile"
    is ValidationError.AntiBotBlock           ->
        "${category.displayName()} at $finalHost (HTTP $statusCode" +
            (if (redirectCount > 0) ", $redirectCount redirect(s)" else "") + ")"
}

internal object ProfileImportPolicy {
    const val MAX_PROFILE_BYTES: Int = 10 * 1024 * 1024

    fun validateSubscriptionUrl(value: String): ValidationError.InvalidSubscriptionUrl? {
        val parsed = value.trim().toHttpUrlOrNull()
            ?: return ValidationError.InvalidSubscriptionUrl("not a valid URL")
        if (parsed.scheme != "https") {
            return ValidationError.InvalidSubscriptionUrl("HTTPS is required")
        }
        if (parsed.host.isBlank()) {
            return ValidationError.InvalidSubscriptionUrl("host is missing")
        }
        return null
    }
}

// ---------------------------------------------------------------------------
// Observability: import log
// ---------------------------------------------------------------------------

internal enum class PipelineStage {
    FETCH, DECODE, YAML_PARSE, BUILD_MODEL, VALIDATE, NORMALIZE, GENERATE_CONFIG, PERSIST
}

internal data class ImportLogEntry(
    val timestampMs: Long,
    val level: LogLevel,
    val stage: PipelineStage,
    val message: String,
)

internal enum class LogLevel { DEBUG, INFO, WARN, ERROR }

internal data class ImportLog(
    val entries: List<ImportLogEntry>,
    val stageDurationsMs: Map<PipelineStage, Long>,
    val totalDurationMs: Long,
)

// Mutable builder used during pipeline execution
internal class ImportLogBuilder(private val startMs: Long = System.currentTimeMillis()) {
    private val entries = mutableListOf<ImportLogEntry>()
    private val stageDurations = mutableMapOf<PipelineStage, Long>()
    private var stageStart = startMs

    fun log(stage: PipelineStage, level: LogLevel, message: String) {
        entries += ImportLogEntry(System.currentTimeMillis(), level, stage, message)
    }

    fun beginStage(stage: PipelineStage) {
        stageStart = System.currentTimeMillis()
        log(stage, LogLevel.DEBUG, "begin")
    }

    fun endStage(stage: PipelineStage) {
        stageDurations[stage] = System.currentTimeMillis() - stageStart
        log(stage, LogLevel.DEBUG, "done (${stageDurations[stage]}ms)")
    }

    fun build(): ImportLog = ImportLog(
        entries          = entries.toList(),
        stageDurationsMs = stageDurations.toMap(),
        totalDurationMs  = System.currentTimeMillis() - startMs,
    )
}

// ---------------------------------------------------------------------------
// Import result
// ---------------------------------------------------------------------------

internal sealed class ImportResult {
    data class Success(
        val profile: ImportedProfile,
        val rawYaml: String,
        val generatedYaml: String,
        val log: ImportLog,
    ) : ImportResult()

    data class Failure(
        val errors: List<ValidationError>,
        val log: ImportLog,
    ) : ImportResult()
}

// ---------------------------------------------------------------------------
// Structured subscription fetch result
// ---------------------------------------------------------------------------

internal sealed class SubscriptionFetchResult {
    data class Success(
        val bytes: ByteArray,
        val finalHost: String,
        val redirectCount: Int,
        val subscriptionUsage: SubscriptionUsage? = null,
    ) : SubscriptionFetchResult()

    data class AntiBotDetected(
        val category: HtmlCategory,
        val statusCode: Int,
        val finalHost: String,
        val redirectCount: Int,
        val redirectTrace: List<String>,
    ) : SubscriptionFetchResult()

    data class Failed(val message: String) : SubscriptionFetchResult()
}
