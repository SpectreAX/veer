package com.yamax.veer.core_profile.internal.parser

import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

/** Finds source fields that the normalized model cannot faithfully emit. */
internal object ConfigCompatibilityAudit {
    // Veer intentionally owns these Android-side runtime settings. They are not
    // imported from a subscription, even when the source config specifies them.
    private val appOwnedRootKeys = setOf(
        "port", "socks-port", "redir-port", "tproxy-port", "mixed-port",
        "allow-lan", "bind-address", "mode", "log-level", "external-controller",
        "secret", "tun", "sniffer", "geo-auto-update", "geox-url",
        "unified-delay", "tcp-concurrent", "ipv6", "profile",
    )
    private val importedRootKeys = setOf("proxies", "proxy-groups", "rules", "dns")
    private val groupKeys = setOf(
        "name", "type", "proxies", "url", "interval", "tolerance", "strategy",
    )
    private val dnsKeys = setOf(
        "enable", "ipv6", "enhanced-mode", "fake-ip-range", "use-hosts",
        "fake-ip-filter", "default-nameserver", "nameserver", "fallback",
        "fallback-filter", "listen", // listen is deliberately replaced by TUN DNS hijack.
    )
    private val fallbackFilterKeys = setOf("geoip", "geoip-code", "ipcidr", "domain", "geosite")
    private val unsupportedRuleTypes = setOf("RULE-SET", "SUB-RULE", "SCRIPT", "AND", "OR", "NOT")
    private val safeKey = Regex("[A-Za-z0-9_-]{1,64}")
    private const val MAX_REPORTED_PATHS = 20

    fun audit(yamlText: String): List<String> {
        val root = try {
            val options = LoaderOptions().apply {
                maxAliasesForCollections = 50
                codePointLimit = 10 * 1024 * 1024
            }
            Yaml(SafeConstructor(options)).load<Any?>(yamlText) as? Map<*, *>
        } catch (_: Exception) {
            // The main parser owns malformed-YAML diagnostics.
            null
        } ?: return emptyList()

        val unsupported = linkedSetOf<String>()
        root.keys.forEach { key ->
            if (key !in importedRootKeys && key !in appOwnedRootKeys) {
                unsupported += pathSegment(key)
            }
        }

        inspectList(root, "proxies", unsupported) { item, index ->
            if (item !is Map<*, *> ||
                listOf("name", "type", "server").any { item[it] == null } ||
                item["port"]?.toString()?.toIntOrNull() == null
            ) {
                unsupported += "proxies[$index]"
            }
        }
        inspectList(root, "proxy-groups", unsupported) { item, index ->
            if (item !is Map<*, *>) {
                unsupported += "proxy-groups[$index]"
            } else {
                if (item["name"] == null || item["type"] == null) {
                    unsupported += "proxy-groups[$index]"
                }
                item.keys.forEach { key ->
                    if (key !in groupKeys) unsupported += "proxy-groups[$index].${pathSegment(key)}"
                }
                inspectStringList(item, "proxies", "proxy-groups[$index].proxies", unsupported)
            }
        }
        inspectList(root, "rules", unsupported) { item, index ->
            val parts = (item as? String)?.trim()?.split(',')?.map(String::trim)
            val valid = parts != null && parts.all(String::isNotBlank) &&
                parts.firstOrNull()?.uppercase() !in unsupportedRuleTypes &&
                when (parts.size) {
                    2 -> true
                    3 -> parts[0].uppercase() != "MATCH"
                    4 -> parts[0].uppercase() != "MATCH" && parts[3].equals("no-resolve", true)
                    else -> false
                }
            if (!valid) unsupported += "rules[$index]"
        }

        val dns = root["dns"]
        if (dns != null && dns !is Map<*, *>) {
            unsupported += "dns"
        } else if (dns is Map<*, *>) {
            dns.keys.forEach { key ->
                if (key !in dnsKeys) unsupported += "dns.${pathSegment(key)}"
            }
            listOf(
                "fake-ip-filter", "default-nameserver", "nameserver", "fallback",
            ).forEach { key -> inspectStringList(dns, key, "dns.$key", unsupported) }
            val filter = dns["fallback-filter"]
            if (filter != null && filter !is Map<*, *>) {
                unsupported += "dns.fallback-filter"
            } else if (filter is Map<*, *>) {
                filter.keys.forEach { key ->
                    if (key !in fallbackFilterKeys) {
                        unsupported += "dns.fallback-filter.${pathSegment(key)}"
                    }
                }
                listOf("ipcidr", "domain", "geosite").forEach { key ->
                    inspectStringList(filter, key, "dns.fallback-filter.$key", unsupported)
                }
            }
        }
        return unsupported.take(MAX_REPORTED_PATHS)
    }

    private inline fun inspectList(
        root: Map<*, *>,
        key: String,
        unsupported: MutableSet<String>,
        inspect: (Any?, Int) -> Unit,
    ) {
        if (key !in root) return
        val items = root[key] as? List<*>
        if (items == null) {
            unsupported += key
        } else {
            items.forEachIndexed { index, item -> inspect(item, index) }
        }
    }

    private fun pathSegment(key: Any?): String =
        (key as? String)?.takeIf(safeKey::matches) ?: "<invalid-key>"

    private fun inspectStringList(
        map: Map<*, *>,
        key: String,
        path: String,
        unsupported: MutableSet<String>,
    ) {
        if (key !in map) return
        val values = map[key] as? List<*>
        if (values == null || values.any { it !is String }) unsupported += path
    }
}
