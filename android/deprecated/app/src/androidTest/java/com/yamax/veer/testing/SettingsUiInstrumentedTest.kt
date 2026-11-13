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
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.ui.settings.SettingsScreen
import com.yamax.veer.ui.theme.ThemeMode
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun unifiedSettingsShowsStatusesAndChangesTheme() {
        var selectedMode = ThemeMode.SYSTEM
        val backgroundStatus = BackgroundRestrictionPolicy.evaluate(
            BackgroundRestrictionSignals(
                oemFamily = OemFamily.OTHER,
                batteryOptimizationExempt = true,
                backgroundRestricted = false,
                standbyBucket = AppStandbyBucket.ACTIVE,
                powerSaveMode = false,
            ),
        )

        composeRule.setContent {
            VeerTheme(themeMode = selectedMode) {
                SettingsScreen(
                    activeProfileName = "测试配置",
                    hasApiKey = true,
                    perAppPolicy = PerAppProxyPolicy(),
                    backgroundStatus = backgroundStatus,
                    themeMode = selectedMode,
                    onBack = {},
                    onSaveApiKey = {},
                    onClearApiKey = {},
                    onOpenDns = {},
                    onOpenPerApp = {},
                    onThemeModeChange = { selectedMode = it },
                    onOpenBatterySettings = {},
                    onOpenAutoStartSettings = {},
                    onOpenApplicationDetails = {},
                )
            }
        }

        composeRule.onNodeWithTag("settings_screen").assertIsDisplayed()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        composeRule.onNodeWithText(
            context.getString(R.string.settings_active_profile, "测试配置"),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(
            context.getString(R.string.settings_api_key_saved),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.theme_dark)).performClick()
        assertEquals(ThemeMode.DARK, selectedMode)
    }
}
