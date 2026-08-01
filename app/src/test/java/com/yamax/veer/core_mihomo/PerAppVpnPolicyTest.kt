package com.yamax.veer.core_mihomo

import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PerAppVpnPolicyTest {
    private val installed = setOf("com.example.browser", "com.example.bank")

    @Test
    fun `all apps excludes Veer to prevent a routing loop`() {
        val plan = build(PerAppProxyPolicy())

        assertEquals(PerAppProxyMode.ALL_APPS, plan.effectiveMode)
        assertEquals(listOf("com.yamax.veer"), plan.disallowedPackages)
        assertTrue(plan.allowedPackages.isEmpty())
        assertFalse(plan.usedFailSafe)
    }

    @Test
    fun `only selected creates an allow list and drops own and stale packages`() {
        val plan = build(
            PerAppProxyPolicy(
                mode = PerAppProxyMode.ONLY_SELECTED,
                packageNames = setOf(
                    "com.example.browser",
                    "com.missing.app",
                    "com.yamax.veer",
                ),
            ),
        )

        assertEquals(listOf("com.example.browser"), plan.allowedPackages)
        assertTrue(plan.disallowedPackages.isEmpty())
        assertEquals(listOf("com.missing.app"), plan.unavailablePackages)
        assertFalse(plan.usedFailSafe)
    }

    @Test
    fun `empty effective allow list falls back to safe all apps mode`() {
        val plan = build(
            PerAppProxyPolicy(
                mode = PerAppProxyMode.ONLY_SELECTED,
                packageNames = setOf("com.missing.app"),
            ),
        )

        assertEquals(PerAppProxyMode.ONLY_SELECTED, plan.requestedMode)
        assertEquals(PerAppProxyMode.ALL_APPS, plan.effectiveMode)
        assertEquals(listOf("com.yamax.veer"), plan.disallowedPackages)
        assertTrue(plan.allowedPackages.isEmpty())
        assertTrue(plan.usedFailSafe)
    }

    @Test
    fun `bypass selected excludes selected apps and Veer`() {
        val plan = build(
            PerAppProxyPolicy(
                mode = PerAppProxyMode.BYPASS_SELECTED,
                packageNames = setOf("com.example.bank", "com.example.browser"),
            ),
        )

        assertEquals(PerAppProxyMode.BYPASS_SELECTED, plan.effectiveMode)
        assertEquals(
            listOf("com.yamax.veer", "com.example.bank", "com.example.browser"),
            plan.disallowedPackages,
        )
        assertTrue(plan.allowedPackages.isEmpty())
    }

    private fun build(policy: PerAppProxyPolicy): PerAppVpnPlan =
        PerAppVpnPolicy.build(
            policy = policy,
            ownPackageName = "com.yamax.veer",
            isInstalled = installed::contains,
        )
}
