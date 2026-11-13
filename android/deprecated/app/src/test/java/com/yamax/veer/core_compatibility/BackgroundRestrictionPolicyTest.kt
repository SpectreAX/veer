package com.yamax.veer.core_compatibility

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundRestrictionPolicyTest {

    @Test
    fun explicitBackgroundRestrictionIsHighestRisk() {
        val status = evaluate(
            backgroundRestricted = true,
            batteryOptimizationExempt = true,
        )

        assertEquals(BackgroundRisk.RESTRICTED, status.risk)
        assertTrue(
            BackgroundRestrictionReason.SYSTEM_BACKGROUND_RESTRICTED in status.reasons,
        )
    }

    @Test
    fun restrictedStandbyBucketIsHighestRisk() {
        val status = evaluate(
            standbyBucket = AppStandbyBucket.RESTRICTED,
            batteryOptimizationExempt = true,
        )

        assertEquals(BackgroundRisk.RESTRICTED, status.risk)
        assertTrue(
            BackgroundRestrictionReason.STANDBY_RESTRICTED in status.reasons,
        )
    }

    @Test
    fun xiaomiAlwaysKeepsManualOemReviewVisible() {
        val status = evaluate(
            oemFamily = OemFamily.XIAOMI,
            batteryOptimizationExempt = true,
        )

        assertEquals(BackgroundRisk.ATTENTION, status.risk)
        assertTrue(status.needsOemReview)
        assertTrue(status.shouldShow)
        assertEquals(
            listOf(BackgroundRestrictionReason.XIAOMI_SETTINGS_UNVERIFIABLE),
            status.reasons,
        )
    }

    @Test
    fun standardBatteryOptimizationProducesAttention() {
        val status = evaluate(batteryOptimizationExempt = false)

        assertEquals(BackgroundRisk.ATTENTION, status.risk)
        assertTrue(
            BackgroundRestrictionReason.BATTERY_OPTIMIZATION_ENABLED in status.reasons,
        )
    }

    @Test
    fun unrestrictedNonOemStateDoesNotInterruptHome() {
        val status = evaluate(batteryOptimizationExempt = true)

        assertEquals(BackgroundRisk.READY, status.risk)
        assertFalse(status.shouldShow)
        assertTrue(status.reasons.isEmpty())
    }

    @Test
    fun oemClassificationCoversXiaomiBrandsCaseInsensitively() {
        assertEquals(
            OemFamily.XIAOMI,
            BackgroundRestrictionPolicy.classifyOem("XIAOMI", "unknown"),
        )
        assertEquals(
            OemFamily.XIAOMI,
            BackgroundRestrictionPolicy.classifyOem("unknown", "Redmi"),
        )
        assertEquals(
            OemFamily.XIAOMI,
            BackgroundRestrictionPolicy.classifyOem(null, "POCO"),
        )
        assertEquals(
            OemFamily.OTHER,
            BackgroundRestrictionPolicy.classifyOem("Google", "Pixel"),
        )
    }

    private fun evaluate(
        oemFamily: OemFamily = OemFamily.OTHER,
        batteryOptimizationExempt: Boolean = true,
        backgroundRestricted: Boolean = false,
        standbyBucket: AppStandbyBucket = AppStandbyBucket.ACTIVE,
        powerSaveMode: Boolean = false,
    ): BackgroundRestrictionStatus = BackgroundRestrictionPolicy.evaluate(
        BackgroundRestrictionSignals(
            oemFamily = oemFamily,
            batteryOptimizationExempt = batteryOptimizationExempt,
            backgroundRestricted = backgroundRestricted,
            standbyBucket = standbyBucket,
            powerSaveMode = powerSaveMode,
        ),
    )
}
