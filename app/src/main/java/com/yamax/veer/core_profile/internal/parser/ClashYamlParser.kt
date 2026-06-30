package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_profile.ImportedProfile
import com.yamax.veer.core_profile.NormalizedDns
import com.yamax.veer.core_profile.NormalizedProxy
import com.yamax.veer.core_profile.NormalizedProxyGroup
import com.yamax.veer.core_profile.NormalizedRule
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

/** Supported Clash proxy type strings. Anything outside this set is rejected. */
private val SUPPORTED_PROXY_TYPES = setOf(
    "ss", "shadowsocks",
    "vmess",
    "vless",
    "trojan",
    "hysteria2",
    "wireguard",
    "socks5",
    "http",
    "tuic",
    "hysteria",
)

/** Proxy fields stored explicitly on [NormalizedProxy]; excluded from [NormalizedProxy.extras]. */
private val COMMON_PROXY_KEYS = setOf("name", "type", "server", "port", "udp")

/** Required fields per proxy type. Values must be non-null/non-blank. */
private val REQUIRED_FIELDS: Map<String, Set<String>> = mapOf(
    "ss"          to setOf("cipher", "password"),
    "shadowsocks" to setOf("cipher", "password"),
    "vmess"       to setOf("uuid"),
    "vless"       to setOf("uuid"),
    "trojan"      to setOf("password"),
    "hysteria2"   to setOf("password"),
    "hysteria"    to setOf("auth-str"),
    "wireguard"   to setOf("private-key"),
    "tuic"        to setOf("uuid", "password"),
    "socks5"      to emptySet(),
    "http"        to emptySet(),
)

/**
 * Parses a raw YAML string (Clash-format) into an [ImportedProfile].
 * All errors are returned as [ValidationError]; no exceptions are thrown.
 */
internal object ClashYamlParser {

    @Suppress("UNCHECKED_CAST")
    fun parse(
        yamlText: String,
        id: ProfileId,
        source: ProfileSource,
        displayName: String,
    ): Result<ImportedProfile> = runCatching {
        val loaderOptions = LoaderOptions().apply {
            maxAliasesForCollections = 50
            codePointLimit = 10 * 1024 * 1024
        }
        val root = Yaml(SafeConstructor(loaderOptions))
            .load<Any>(yamlText) as? Map<String, Any?>
            ?: error("YAML root must be a mapping")

        val proxies = parseProxies(root)
        val groups  = parseProxyGroups(root)
        val rules   = parseRules(root)
        val dns     = parseDns(root)

        val now = System.currentTimeMillis()
        val meta = ProfileMetadata(
            id              = id,
            displayName     = displayName,
            source          = source,
            importedAtMs    = now,
            lastUpdatedMs   = now,
            proxyCount      = proxies.size,
            groupCount      = groups.size,
            ruleCount       = rules.size,
            rawSizeBytes    = yamlText.toByteArray().size.toLong(),
            configHashSha256 = "", // filled in by ProfileParser after generation
        )

        ImportedProfile(
            id         = id,
            metadata   = meta,
            proxies    = proxies,
            proxyGroups = groups,
            rules      = rules,
            dns        = dns,
        )
    }

    // -------------------------------------------------------------------------
    // Proxies
    // -------------------------------------------------------------------------

    @Suppress("UNCHECKED_CAST")
    private fun parseProxies(root: Map<String, Any?>): List<NormalizedProxy> {
        val rawList = root.list("proxies") ?: return emptyList()
        return rawList.mapNotNull { item ->
            val m = item as? Map<String, Any?> ?: return@mapNotNull null
            val name   = m.str("name")   ?: return@mapNotNull null
            val type   = m.str("type")   ?: return@mapNotNull null
            val server = m.str("server") ?: return@mapNotNull null
            val port   = m.int("port")   ?: return@mapNotNull null
            val udp    = m.bool("udp") ?: true
            val extras = m.entries
                .filter { it.key !in COMMON_PROXY_KEYS }
                .associate { (k, v) -> k to v.toJsonElement() }
            NormalizedProxy(name = name, type = type, server = server,
                port = port, udp = udp, extras = extras)
        }
    }

    // -------------------------------------------------------------------------
    // Proxy groups
    // -------------------------------------------------------------------------

    @Suppress("UNCHECKED_CAST")
    private fun parseProxyGroups(root: Map<String, Any?>): List<NormalizedProxyGroup> {
        val rawList = root.list("proxy-groups") ?: return emptyList()
        return rawList.mapNotNull { item ->
            val m       = item as? Map<String, Any?> ?: return@mapNotNull null
            val name    = m.str("name")  ?: return@mapNotNull null
            val type    = m.str("type")  ?: return@mapNotNull null
            val proxies = m.strList("proxies") ?: emptyList()
            NormalizedProxyGroup(
                name     = name,
                type     = type,
                proxies  = proxies,
                url      = m.str("url"),
                interval = m.int("interval"),
                tolerance = m.int("tolerance"),
                strategy = m.str("strategy"),
            )
        }
    }

    // -------------------------------------------------------------------------
    // Rules
    // -------------------------------------------------------------------------

    private fun parseRules(root: Map<String, Any?>): List<NormalizedRule> {
        val rawList = root.strList("rules") ?: return emptyList()
        return rawList.mapNotNull { parseRule(it) }
    }

    private fun parseRule(line: String): NormalizedRule? {
        val parts = line.trim().split(',').map { it.trim() }
        return when {
            parts.size == 1 && parts[0].uppercase() == "MATCH" ->
                NormalizedRule("MATCH", null, "DIRECT")

            parts.size == 2 ->
                NormalizedRule(parts[0].uppercase(), null, parts[1])

            parts.size >= 3 -> {
                val noResolve = parts.getOrNull(3)?.lowercase() == "no-resolve"
                NormalizedRule(parts[0].uppercase(), parts[1], parts[2], noResolve)
            }

            else -> null
        }
    }

    // -------------------------------------------------------------------------
    // DNS
    // -------------------------------------------------------------------------

    private fun parseDns(root: Map<String, Any?>): NormalizedDns? {
        val dns = root.map("dns") ?: return null
        val enabled = dns.bool("enable") ?: false
        return NormalizedDns(
            enabled             = enabled,
            ipv6                = dns.bool("ipv6") ?: false,
            enhancedMode        = dns.str("enhanced-mode"),
            fakeDnsFilter       = dns.strList("fake-ip-filter") ?: emptyList(),
            nameservers         = dns.strList("nameserver") ?: emptyList(),
            fallbackNameservers = dns.strList("fallback")   ?: emptyList(),
        )
    }

    // -------------------------------------------------------------------------
    // Validation helpers (used by ProfileValidator)
    // -------------------------------------------------------------------------

    fun isSupportedType(type: String): Boolean = type.lowercase() in SUPPORTED_PROXY_TYPES

    fun requiredFields(type: String): Set<String> =
        REQUIRED_FIELDS[type.lowercase()] ?: emptySet()
}
