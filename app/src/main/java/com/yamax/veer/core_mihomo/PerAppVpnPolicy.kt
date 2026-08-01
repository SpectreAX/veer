package com.yamax.veer.core_mihomo

import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicy

internal data class PerAppVpnPlan(
    val requestedMode: PerAppProxyMode,
    val effectiveMode: PerAppProxyMode,
    val allowedPackages: List<String>,
    val disallowedPackages: List<String>,
    val unavailablePackages: List<String>,
) {
    val usedFailSafe: Boolean
        get() = requestedMode != effectiveMode
}

/**
 * Produces an immutable Builder plan before any allow/disallow method is called.
 *
 * Android forbids mixing `addAllowedApplication` and
 * `addDisallowedApplication` on one Builder. Preflight also lets an empty or
 * stale allow-list fail open to the normal all-apps policy instead of
 * establishing a VPN that carries no application traffic.
 */
internal object PerAppVpnPolicy {
    fun build(
        policy: PerAppProxyPolicy,
        ownPackageName: String,
        isInstalled: (String) -> Boolean,
    ): PerAppVpnPlan {
        val normalized = policy.normalized()
        val selected = normalized.packageNames
            .filterNot { it == ownPackageName }
        val (installed, unavailable) = selected.partition(isInstalled)
        val available = installed.sorted()

        return when (normalized.mode) {
            PerAppProxyMode.ALL_APPS -> PerAppVpnPlan(
                requestedMode = normalized.mode,
                effectiveMode = normalized.mode,
                allowedPackages = emptyList(),
                disallowedPackages = listOf(ownPackageName),
                unavailablePackages = unavailable.sorted(),
            )

            PerAppProxyMode.BYPASS_SELECTED -> PerAppVpnPlan(
                requestedMode = normalized.mode,
                effectiveMode = normalized.mode,
                allowedPackages = emptyList(),
                disallowedPackages = (listOf(ownPackageName) + available).distinct(),
                unavailablePackages = unavailable.sorted(),
            )

            PerAppProxyMode.ONLY_SELECTED -> {
                if (available.isEmpty()) {
                    PerAppVpnPlan(
                        requestedMode = normalized.mode,
                        effectiveMode = PerAppProxyMode.ALL_APPS,
                        allowedPackages = emptyList(),
                        disallowedPackages = listOf(ownPackageName),
                        unavailablePackages = unavailable.sorted(),
                    )
                } else {
                    PerAppVpnPlan(
                        requestedMode = normalized.mode,
                        effectiveMode = normalized.mode,
                        allowedPackages = available,
                        disallowedPackages = emptyList(),
                        unavailablePackages = unavailable.sorted(),
                    )
                }
            }
        }
    }
}
