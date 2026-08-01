package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.core_compatibility.AppStandbyBucket
import com.yamax.veer.core_compatibility.BackgroundRestrictionPolicy
import com.yamax.veer.core_compatibility.BackgroundRestrictionSignals
import com.yamax.veer.core_compatibility.OemFamily
import com.yamax.veer.ui.BackgroundProtectionCard
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.RuleChain

@RunWith(AndroidJUnit4::class)
class BackgroundProtectionUiInstrumentedTest {

    private val composeRule = createComposeRule()
    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun xiaomiReviewExpandsToExplicitSettingsActions() {
        val status = BackgroundRestrictionPolicy.evaluate(
            BackgroundRestrictionSignals(
                oemFamily = OemFamily.XIAOMI,
                batteryOptimizationExempt = true,
                backgroundRestricted = false,
                standbyBucket = AppStandbyBucket.ACTIVE,
                powerSaveMode = false,
            ),
        )

        composeRule.setContent {
            VeerTheme {
                BackgroundProtectionCard(
                    status = status,
                    onOpenBatterySettings = {},
                    onOpenAutoStartSettings = {},
                    onOpenApplicationDetails = {},
                )
            }
        }

        composeRule.onNodeWithTag("background_protection_card").assertIsDisplayed()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        composeRule.onNodeWithText(
            context.getString(R.string.background_protection_title),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.common_check)).performClick()
        composeRule.onNodeWithText(
            context.getString(R.string.background_battery_settings),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(
            context.getString(R.string.background_autostart_settings),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(
            context.getString(R.string.background_app_details),
        ).assertIsDisplayed()
    }
}
