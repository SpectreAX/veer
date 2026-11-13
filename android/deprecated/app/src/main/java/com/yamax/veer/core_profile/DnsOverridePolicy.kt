package com.yamax.veer.core_profile

import kotlinx.serialization.Serializable
import java.net.InetAddress
import java.net.URI

@Serializable
internal enum class DnsOverrideMode {
    INHERIT,
    CUSTOM,
}

@Serializable
internal enum class DnsEnhancedMode(val wireValue: String) {
    FAKE_IP("fake-ip"),
    REDIR_HOST("redir-host"),
}

@Serializable
internal data class DnsOverridePolicy(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val mode: DnsOverrideMode = DnsOverrideMode.INHERIT,
    val ipv6: Boolean = false,
    val enhancedMode: DnsEnhancedMode = DnsEnhancedMode.FAKE_IP,
    val defaultNameservers: List<String> = emptyList(),
    val nameservers: List<String> = emptyList(),
    val fallbackNameservers: List<String> = emptyList(),
) {
    fun normalized(): DnsOverridePolicy {
        if (mode == DnsOverrideMode.INHERIT) return DnsOverridePolicy()
        return copy(
            schemaVersion = CURRENT_SCHEMA_VERSION,
            defaultNameservers = defaultNameservers.normalizedEndpoints(),
            nameservers = nameservers.normalizedEndpoints(),
            fallbackNameservers = fallbackNameservers.normalizedEndpoints(),
        )
    }

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
        const val MAX_ENDPOINTS_PER_GROUP = 8
        const val MAX_ENDPOINT_LENGTH = 512

        fun recommendedCustom(): DnsOverridePolicy = DnsOverridePolicy(
            mode = DnsOverrideMode.CUSTOM,
            defaultNameservers = listOf("223.5.5.5", "1.1.1.1"),
            nameservers = listOf(
                "https://1.1.1.1/dns-query",
                "https://cloudflare-dns.com/dns-query",
            ),
        )
    }
}

internal enum class DnsSettingField {
    DEFAULT_NAMESERVERS,
    NAMESERVERS,
    FALLBACK_NAMESERVERS,
}

internal data class DnsValidationIssue(
    val field: DnsSettingField,
    val index: Int?,
    val problem: DnsValidationProblem,
    val argument: String? = null,
) {
    /** Stable, non-localized diagnostic text for logs and thrown exceptions. */
    fun diagnosticMessage(): String = buildString {
        append(field.name)
        index?.let { append('[').append(it).append(']') }
        append(':').append(problem.name)
        argument?.let { append('(').append(it).append(')') }
    }
}

internal enum class DnsValidationProblem {
    REQUIRED,
    TOO_MANY,
    TOO_LONG,
    BOOTSTRAP_IP_ONLY,
    INVALID_ADDRESS,
    BARE_DOMAIN_REQUIRES_PROTOCOL,
    UNSUPPORTED_SCHEME,
    CREDENTIALS_NOT_ALLOWED,
    MISSING_HOST,
    INVALID_PORT,
    FRAGMENT_NOT_ALLOWED,
    DOH_PATH_REQUIRED,
    PATH_NOT_ALLOWED,
}

internal object DnsOverrideValidator {
    private val endpointSchemes = setOf("https", "tls", "tcp", "udp", "quic")

    fun validate(policy: DnsOverridePolicy): List<DnsValidationIssue> {
        val normalized = policy.normalized()
        if (normalized.mode == DnsOverrideMode.INHERIT) return emptyList()

        return buildList {
            validateGroup(
                DnsSettingField.DEFAULT_NAMESERVERS,
                normalized.defaultNameservers,
                ipOnly = true,
                required = true,
            )
            validateGroup(
                DnsSettingField.NAMESERVERS,
                normalized.nameservers,
                ipOnly = false,
                required = true,
            )
            validateGroup(
                DnsSettingField.FALLBACK_NAMESERVERS,
                normalized.fallbackNameservers,
                ipOnly = false,
                required = false,
            )
        }
    }

    fun isIpLiteral(value: String): Boolean {
        val candidate = value.trim().removeSurrounding("[", "]")
        val numericShape = when {
            candidate.contains(':') ->
                candidate.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' }
            candidate.count { it == '.' } == 3 ->
                candidate.all { it.isDigit() || it == '.' }
            else -> false
        }
        if (!numericShape) return false
        return runCatching { InetAddress.getByName(candidate) }.isSuccess
    }

    private fun MutableList<DnsValidationIssue>.validateGroup(
        field: DnsSettingField,
        values: List<String>,
        ipOnly: Boolean,
        required: Boolean,
    ) {
        if (required && values.isEmpty()) {
            add(DnsValidationIssue(field, null, DnsValidationProblem.REQUIRED))
            return
        }
        if (values.size > DnsOverridePolicy.MAX_ENDPOINTS_PER_GROUP) {
            add(
                DnsValidationIssue(
                    field,
                    null,
                    DnsValidationProblem.TOO_MANY,
                    DnsOverridePolicy.MAX_ENDPOINTS_PER_GROUP.toString(),
                ),
            )
        }
        values.forEachIndexed { index, endpoint ->
            endpointError(endpoint, ipOnly)?.let { error ->
                add(DnsValidationIssue(field, index, error.problem, error.argument))
            }
        }
    }

    private data class EndpointError(
        val problem: DnsValidationProblem,
        val argument: String? = null,
    )

    private fun endpointError(value: String, ipOnly: Boolean): EndpointError? {
        if (value.length > DnsOverridePolicy.MAX_ENDPOINT_LENGTH) {
            return EndpointError(
                DnsValidationProblem.TOO_LONG,
                DnsOverridePolicy.MAX_ENDPOINT_LENGTH.toString(),
            )
        }
        if (isIpLiteral(value)) return null
        if (ipOnly) return EndpointError(DnsValidationProblem.BOOTSTRAP_IP_ONLY)

        val uri = runCatching { URI(value) }.getOrNull()
            ?: return EndpointError(DnsValidationProblem.INVALID_ADDRESS)
        val scheme = uri.scheme?.lowercase()
            ?: return EndpointError(DnsValidationProblem.BARE_DOMAIN_REQUIRES_PROTOCOL)
        if (scheme !in endpointSchemes) {
            return EndpointError(DnsValidationProblem.UNSUPPORTED_SCHEME, scheme)
        }
        if (uri.rawUserInfo != null) {
            return EndpointError(DnsValidationProblem.CREDENTIALS_NOT_ALLOWED)
        }
        if (uri.host.isNullOrBlank()) return EndpointError(DnsValidationProblem.MISSING_HOST)
        if (uri.port !in -1..65535 || uri.port == 0) {
            return EndpointError(DnsValidationProblem.INVALID_PORT)
        }
        if (uri.rawFragment != null) {
            return EndpointError(DnsValidationProblem.FRAGMENT_NOT_ALLOWED)
        }
        if (scheme == "https" && (uri.rawPath.isNullOrBlank() || uri.rawPath == "/")) {
            return EndpointError(DnsValidationProblem.DOH_PATH_REQUIRED)
        }
        if (scheme != "https" && !uri.rawPath.isNullOrBlank() && uri.rawPath != "/") {
            return EndpointError(DnsValidationProblem.PATH_NOT_ALLOWED, scheme.uppercase())
        }
        return null
    }
}

private fun List<String>.normalizedEndpoints(): List<String> =
    map(String::trim).filter(String::isNotEmpty).distinct()
