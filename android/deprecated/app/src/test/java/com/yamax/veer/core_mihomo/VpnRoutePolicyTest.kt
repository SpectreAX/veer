package com.yamax.veer.core_mihomo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger
import java.net.InetAddress

class VpnRoutePolicyTest {

    @Test
    fun `bypass disabled installs only IPv4 and IPv6 defaults`() {
        val plan = VpnRoutePolicy.build(
            bypassLan = false,
            supportsExcludeRoute = true,
        )

        assertEquals(
            listOf(VpnCidr("0.0.0.0", 0), VpnCidr("::", 0)),
            plan.included,
        )
        assertTrue(plan.excluded.isEmpty())
    }

    @Test
    fun `API 33 plan excludes local and multicast address space`() {
        val plan = VpnRoutePolicy.build(
            bypassLan = true,
            supportsExcludeRoute = true,
        )

        assertEquals(
            listOf(VpnCidr("0.0.0.0", 0), VpnCidr("::", 0)),
            plan.included,
        )
        assertEquals(
            listOf(
                VpnCidr("10.0.0.0", 8),
                VpnCidr("172.16.0.0", 12),
                VpnCidr("192.168.0.0", 16),
                VpnCidr("169.254.0.0", 16),
                VpnCidr("224.0.0.0", 4),
                VpnCidr("fc00::", 7),
                VpnCidr("fe80::", 10),
            ),
            plan.excluded,
        )
    }

    @Test
    fun `API 29 fallback IPv4 routes are exact complement of local bypass blocks`() {
        val routes = VpnRoutePolicy.IPV4_LAN_BYPASS_ROUTES

        listOf(
            "10.0.0.1",
            "172.16.0.1",
            "192.168.0.1",
            "169.254.0.1",
            "224.0.0.251",
            "239.255.255.250",
        ).forEach { address ->
            assertFalse("$address must bypass the tunnel", routes.contains(address))
        }
        listOf(
            "1.1.1.1",
            "100.64.0.1",
            "169.253.255.255",
            "169.255.0.1",
            "223.255.255.255",
            "240.0.0.1",
        ).forEach { address ->
            assertTrue("$address must remain tunneled", routes.contains(address))
        }

        val covered = routes.sumOf { route ->
            BigInteger.ONE.shiftLeft(32 - route.prefixLength)
        }
        val excludedPrefixLengths = listOf(8, 12, 16, 16, 4)
        val expected = excludedPrefixLengths.fold(
            BigInteger.ONE.shiftLeft(32),
        ) { total, prefixLength ->
            total.subtract(BigInteger.ONE.shiftLeft(32 - prefixLength))
        }
        assertEquals(expected, covered)
        assertNoOverlaps(routes)
    }

    @Test
    fun `API 29 fallback IPv6 routes are exact complement of ULA and link local`() {
        val routes = VpnRoutePolicy.IPV6_LAN_BYPASS_ROUTES

        listOf(
            "fc00::",
            "fdfe:dcba:9876::1",
            "fe80::1",
            "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        ).forEach { address ->
            assertFalse("$address must bypass the tunnel", routes.contains(address))
        }
        listOf(
            "::1",
            "2001:4860:4860::8888",
            "fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fec0::1",
            "ff02::fb",
        ).forEach { address ->
            assertTrue("$address must remain tunneled", routes.contains(address))
        }

        val covered = routes.sumOf { route ->
            BigInteger.ONE.shiftLeft(128 - route.prefixLength)
        }
        val expected = BigInteger.ONE.shiftLeft(128)
            .subtract(BigInteger.ONE.shiftLeft(128 - 7))
            .subtract(BigInteger.ONE.shiftLeft(128 - 10))
        assertEquals(expected, covered)
        assertNoOverlaps(routes)
    }

    @Test
    fun `API 29 fallback combines IPv4 and IPv6 complements without exclusions`() {
        val plan = VpnRoutePolicy.build(
            bypassLan = true,
            supportsExcludeRoute = false,
        )

        assertEquals(
            VpnRoutePolicy.IPV4_LAN_BYPASS_ROUTES +
                VpnRoutePolicy.IPV6_LAN_BYPASS_ROUTES,
            plan.included,
        )
        assertTrue(plan.excluded.isEmpty())
        assertFalse(plan.included.contains(VpnCidr("::", 0)))
        assertFalse(plan.included.contains(VpnCidr("0.0.0.0", 0)))
    }

    private fun List<VpnCidr>.contains(address: String): Boolean =
        any { route -> route.contains(address) }

    private fun VpnCidr.contains(candidate: String): Boolean {
        val networkBytes = InetAddress.getByName(address).address
        val candidateBytes = InetAddress.getByName(candidate).address
        if (networkBytes.size != candidateBytes.size) return false
        var bits = prefixLength
        for (index in networkBytes.indices) {
            if (bits <= 0) return true
            val mask = if (bits >= 8) 0xff else (0xff shl (8 - bits)) and 0xff
            if (
                (networkBytes[index].toInt() and mask) !=
                (candidateBytes[index].toInt() and mask)
            ) {
                return false
            }
            bits -= 8
        }
        return true
    }

    private fun assertNoOverlaps(routes: List<VpnCidr>) {
        routes.forEachIndexed { firstIndex, first ->
            routes.drop(firstIndex + 1).forEach { second ->
                assertFalse(
                    "$first overlaps $second",
                    first.contains(second.address) || second.contains(first.address),
                )
            }
        }
    }
}
