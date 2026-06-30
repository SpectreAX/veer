package com.yamax.veer.core_profile

import kotlinx.serialization.json.JsonElement

/**
 * Fully parsed, validated, and normalized internal representation of a user-supplied
 * Clash-format profile. This type never touches Mihomo directly — use
 * [RuntimeConfigGenerator] to produce a safe runtime YAML from it.
 */
internal data class ImportedProfile(
    val id: ProfileId,
    val metadata: ProfileMetadata,
    val proxies: List<NormalizedProxy>,
    val proxyGroups: List<NormalizedProxyGroup>,
    val rules: List<NormalizedRule>,
    val dns: NormalizedDns?,
)

/**
 * Normalized proxy entry. [type] is the lowercase Clash proxy type string (ss, vmess, …).
 * [extras] holds all type-specific fields from the original YAML, converted to [JsonElement]
 * so they can survive serialization to disk if needed.
 */
internal data class NormalizedProxy(
    val name: String,
    val type: String,
    val server: String,
    val port: Int,
    val udp: Boolean,
    val extras: Map<String, JsonElement>,
)

internal data class NormalizedProxyGroup(
    val name: String,
    /** Clash group type: "select", "url-test", "fallback", "load-balance", "relay". */
    val type: String,
    /** Ordered list of proxy names and built-in targets (DIRECT, REJECT). */
    val proxies: List<String>,
    val url: String? = null,
    val interval: Int? = null,
    val tolerance: Int? = null,
    val strategy: String? = null,
)

internal data class NormalizedRule(
    /** Rule type: DOMAIN, DOMAIN-SUFFIX, IP-CIDR, GEOIP, RULE-SET, MATCH, etc. */
    val type: String,
    /** Null only for the MATCH catch-all rule. */
    val payload: String?,
    /** Target proxy group name, DIRECT, or REJECT. */
    val target: String,
    val noResolve: Boolean = false,
) {
    fun toRuleString(): String = buildString {
        append(type)
        if (payload != null) { append(','); append(payload) }
        append(','); append(target)
        if (noResolve) append(",no-resolve")
    }
}

internal data class NormalizedDns(
    val enabled: Boolean,
    val ipv6: Boolean,
    val enhancedMode: String?,          // "fake-ip" | "redir-host" | null
    val fakeDnsFilter: List<String>,
    val nameservers: List<String>,
    val fallbackNameservers: List<String>,
)
