package com.yamax.veer.core_mihomo

/**
 * Android VPN route plan independent of framework classes so the exact
 * include/exclude contract can be unit-tested on the host JVM.
 */
internal data class VpnCidr(
    val address: String,
    val prefixLength: Int,
)

internal data class VpnRoutePlan(
    val included: List<VpnCidr>,
    val excluded: List<VpnCidr>,
)

internal object VpnRoutePolicy {
    private val DEFAULT_ROUTES = listOf(
        VpnCidr("0.0.0.0", 0),
        VpnCidr("::", 0),
    )

    // Ranges left on the underlying network when LAN bypass is enabled.
    val LAN_BYPASS_BLOCKS = listOf(
        VpnCidr("10.0.0.0", 8),
        VpnCidr("172.16.0.0", 12),
        VpnCidr("192.168.0.0", 16),
        VpnCidr("169.254.0.0", 16),
        VpnCidr("224.0.0.0", 4),
        VpnCidr("fc00::", 7),
        VpnCidr("fe80::", 10),
    )

    // API 29–32 fallback for Builder.excludeRoute(). This is the exact IPv4
    // complement of RFC1918, link-local and multicast.
    val IPV4_LAN_BYPASS_ROUTES = listOf(
        VpnCidr("0.0.0.0", 5),
        VpnCidr("8.0.0.0", 7),
        VpnCidr("11.0.0.0", 8),
        VpnCidr("12.0.0.0", 6),
        VpnCidr("16.0.0.0", 4),
        VpnCidr("32.0.0.0", 3),
        VpnCidr("64.0.0.0", 2),
        VpnCidr("128.0.0.0", 3),
        VpnCidr("160.0.0.0", 5),
        VpnCidr("168.0.0.0", 8),
        VpnCidr("169.0.0.0", 9),
        VpnCidr("169.128.0.0", 10),
        VpnCidr("169.192.0.0", 11),
        VpnCidr("169.224.0.0", 12),
        VpnCidr("169.240.0.0", 13),
        VpnCidr("169.248.0.0", 14),
        VpnCidr("169.252.0.0", 15),
        VpnCidr("169.255.0.0", 16),
        VpnCidr("170.0.0.0", 7),
        VpnCidr("172.0.0.0", 12),
        VpnCidr("172.32.0.0", 11),
        VpnCidr("172.64.0.0", 10),
        VpnCidr("172.128.0.0", 9),
        VpnCidr("173.0.0.0", 8),
        VpnCidr("174.0.0.0", 7),
        VpnCidr("176.0.0.0", 4),
        VpnCidr("192.0.0.0", 9),
        VpnCidr("192.128.0.0", 11),
        VpnCidr("192.160.0.0", 13),
        VpnCidr("192.169.0.0", 16),
        VpnCidr("192.170.0.0", 15),
        VpnCidr("192.172.0.0", 14),
        VpnCidr("192.176.0.0", 12),
        VpnCidr("192.192.0.0", 10),
        VpnCidr("193.0.0.0", 8),
        VpnCidr("194.0.0.0", 7),
        VpnCidr("196.0.0.0", 6),
        VpnCidr("200.0.0.0", 5),
        VpnCidr("208.0.0.0", 4),
        VpnCidr("240.0.0.0", 4),
    )

    // Exact IPv6 complement of ULA fc00::/7 and link-local fe80::/10.
    // Multicast ff00::/8 remains tunneled; changing that is a separate policy.
    val IPV6_LAN_BYPASS_ROUTES = listOf(
        VpnCidr("::", 1),
        VpnCidr("8000::", 2),
        VpnCidr("c000::", 3),
        VpnCidr("e000::", 4),
        VpnCidr("f000::", 5),
        VpnCidr("f800::", 6),
        VpnCidr("fe00::", 9),
        VpnCidr("fec0::", 10),
        VpnCidr("ff00::", 8),
    )

    fun build(
        bypassLan: Boolean,
        supportsExcludeRoute: Boolean,
    ): VpnRoutePlan {
        if (!bypassLan) {
            return VpnRoutePlan(included = DEFAULT_ROUTES, excluded = emptyList())
        }
        if (supportsExcludeRoute) {
            return VpnRoutePlan(
                included = DEFAULT_ROUTES,
                excluded = LAN_BYPASS_BLOCKS,
            )
        }
        return VpnRoutePlan(
            included = IPV4_LAN_BYPASS_ROUTES + IPV6_LAN_BYPASS_ROUTES,
            excluded = emptyList(),
        )
    }
}
