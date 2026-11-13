package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_profile.ImportedProfile
import com.yamax.veer.core_profile.NormalizedDns
import com.yamax.veer.core_profile.NormalizedProxy
import com.yamax.veer.core_profile.NormalizedProxyGroup
import com.yamax.veer.core_profile.NormalizedRule
import com.yamax.veer.core_profile.SubscriptionMetadata

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
        val normalizedProxies = deduplicateAndNormalizeProxies(profile.proxies)
        val metadataNames = normalizedProxies.asSequence()
            .map { it.name }
            .filter(SubscriptionMetadata::isLikelyMetadataName)
            .toSet()
        val proxies     = normalizedProxies.filterNot { it.name in metadataNames }
        val proxyNames  = proxies.map { it.name }.toSet()
        val groups      = normalizeGroups(profile.proxyGroups, metadataNames)
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

    private fun normalizeGroups(
        groups: List<NormalizedProxyGroup>,
        metadataNames: Set<String>,
    ): List<NormalizedProxyGroup> =
        groups.map { g ->
            g.copy(
                name = g.name.sanitize(),
                type = g.type.lowercase(),
                proxies = g.proxies
                    .map { it.sanitize() }
                    .filterNot { it in metadataNames }
                    .distinct(),
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
        // Keep the profile's fallback resolvers: they are commonly the only
        // unpolluted answers for foreign domains on restricted networks.
        return dns.copy(
            defaultNameservers  = dns.defaultNameservers.filter { it.isNotBlank() }.distinct(),
            nameservers         = dns.nameservers.filter { it.isNotBlank() },
            fallbackNameservers = dns.fallbackNameservers.filter { it.isNotBlank() }.distinct(),
            fallbackFilter      = dns.fallbackFilter?.copy(
                ipCidrs  = dns.fallbackFilter.ipCidrs.filter { it.isNotBlank() }.distinct(),
                domains = dns.fallbackFilter.domains.filter { it.isNotBlank() }.distinct(),
                geoSites = dns.fallbackFilter.geoSites.filter { it.isNotBlank() }.distinct(),
            ),
        )
    }

    private fun String.sanitize(): String =
        filter { it >= ' ' }.trim()
}
