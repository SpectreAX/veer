package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_profile.ImportedProfile
import com.yamax.veer.core_profile.NormalizedProxy
import com.yamax.veer.core_profile.NormalizedProxyGroup
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal object ProfileValidator {

    private val PORT_RANGE = 1..65535

    /** Built-in Clash targets that are always valid and need no proxy definition. */
    private val BUILTIN_TARGETS = setOf("DIRECT", "REJECT", "PASS", "COMPATIBLE")

    fun validate(profile: ImportedProfile): List<ValidationError> {
        val errors = mutableListOf<ValidationError>()

        if (profile.proxies.isEmpty()) errors += ValidationError.NoProxies
        if (profile.proxyGroups.isEmpty()) errors += ValidationError.NoProxyGroups

        val proxyNames = profile.proxies.map { it.name }.toSet()
        val groupNames = profile.proxyGroups.map { it.name }.toSet()
        val validTargets = proxyNames + groupNames + BUILTIN_TARGETS

        checkDuplicateProxies(profile.proxies, errors)
        checkProxyFields(profile.proxies, errors)
        checkProxyGroups(profile.proxyGroups, validTargets, errors)

        return errors
    }

    private fun checkDuplicateProxies(
        proxies: List<NormalizedProxy>,
        errors: MutableList<ValidationError>,
    ) {
        val seen = mutableSetOf<String>()
        for (p in proxies) {
            if (!seen.add(p.name)) errors += ValidationError.DuplicateProxy(p.name)
        }
    }

    private fun checkProxyFields(
        proxies: List<NormalizedProxy>,
        errors: MutableList<ValidationError>,
    ) {
        for (p in proxies) {
            if (!ClashYamlParser.isSupportedType(p.type))
                errors += ValidationError.UnsupportedProxyType(p.name, p.type)

            if (p.port !in PORT_RANGE)
                errors += ValidationError.InvalidPort(p.name, p.port)

            for (field in ClashYamlParser.requiredFields(p.type)) {
                val element = p.extras[field]
                val missing = element == null
                    || (element is JsonPrimitive && element.contentOrNull.isNullOrBlank())
                if (missing) errors += ValidationError.MissingRequiredField(p.name, field)
            }
        }
    }

    private fun checkProxyGroups(
        groups: List<NormalizedProxyGroup>,
        validTargets: Set<String>,
        errors: MutableList<ValidationError>,
    ) {
        for (g in groups) {
            if (g.proxies.isEmpty()) {
                errors += ValidationError.EmptyProxyGroup(g.name)
                continue
            }
            for (ref in g.proxies) {
                if (ref !in validTargets)
                    errors += ValidationError.BrokenGroupReference(g.name, ref)
            }
        }
    }
}
