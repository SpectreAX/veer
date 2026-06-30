package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_profile.ImportedProfile
import com.yamax.veer.core_profile.NormalizedDns
import com.yamax.veer.core_profile.NormalizedProxy
import com.yamax.veer.core_profile.NormalizedProxyGroup
import com.yamax.veer.core_profile.NormalizedRule

/**
 * Produces a clean [ImportedProfile] from a parsed one:
 * - Deduplicates proxies (keeps first occurrence)
 * - Normalizes proxy type to lowercase
 * - Sanitizes display names (strips control characters)
 * - Removes rules that reference no known target
 * - Ensures at least one MATCH rule exists as final catch-all
 */
internal object ProfileNormalizer {

    fun normalize(profile: ImportedProfile): ImportedProfile {
        val proxies     = deduplicateAndNormalizeProxies(profile.proxies)
        val proxyNames  = proxies.map { it.name }.toSet()
        val groups      = normalizeGroups(profile.proxyGroups)
        val groupNames  = groups.map { it.name }.toSet()
        val validTargets = proxyNames + groupNames + setOf("DIRECT", "REJECT", "PASS", "COMPATIBLE")
        val rules       = normalizeRules(profile.rules, validTargets)
        val dns         = normalizeDns(profile.dns)

        return profile.copy(
            proxies     = proxies,
            proxyGroups = groups,
            rules       = rules,
            dns         = dns,
        )
    }

    private fun deduplicateAndNormalizeProxies(proxies: List<NormalizedProxy>): List<NormalizedProxy> {
        val seen = mutableSetOf<String>()
        return proxies
            .filter { seen.add(it.name) }
            .map { it.copy(type = it.type.lowercase(), name = it.name.sanitize()) }
    }

    private fun normalizeGroups(groups: List<NormalizedProxyGroup>): List<NormalizedProxyGroup> =
        groups.map { g ->
            g.copy(
                name = g.name.sanitize(),
                type = g.type.lowercase(),
                proxies = g.proxies.map { it.sanitize() },
            )
        }

    private fun normalizeRules(
        rules: List<NormalizedRule>,
        validTargets: Set<String>,
    ): List<NormalizedRule> {
        val filtered = rules.filter { it.target in validTargets }
        // Ensure there is a terminal MATCH rule; add DIRECT fallback if missing
        val hasMatch = filtered.any { it.type == "MATCH" }
        return if (hasMatch) filtered else filtered + NormalizedRule("MATCH", null, "DIRECT")
    }

    private fun normalizeDns(dns: NormalizedDns?): NormalizedDns? {
        if (dns == null || !dns.enabled) return null
        // Strip blank entries from nameserver lists
        return dns.copy(
            nameservers         = dns.nameservers.filter { it.isNotBlank() },
            fallbackNameservers = dns.fallbackNameservers.filter { it.isNotBlank() },
        )
    }

    private fun String.sanitize(): String =
        filter { it >= ' ' }.trim()
}
