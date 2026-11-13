package com.yamax.veer.ui.settings

import com.yamax.veer.R
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.ui.theme.ThemeMode
import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsPresentationTest {
    @Test
    fun perAppSummaryKeepsDirectionAndCountAsTypedArguments() {
        assertEquals(
            SettingsText(R.string.settings_per_app_all),
            PerAppProxyPolicy().settingsSummaryText(),
        )
        assertEquals(
            SettingsText(R.string.settings_per_app_only, 2),
            PerAppProxyPolicy(
                mode = PerAppProxyMode.ONLY_SELECTED,
                packageNames = setOf("one", "two"),
            ).settingsSummaryText(),
        )
        assertEquals(
            SettingsText(R.string.settings_per_app_bypass, 1),
            PerAppProxyPolicy(
                mode = PerAppProxyMode.BYPASS_SELECTED,
                packageNames = setOf("one"),
            ).settingsSummaryText(),
        )
    }

    @Test
    fun allThemeModesHaveClearLabels() {
        assertEquals(R.string.theme_system, ThemeMode.SYSTEM.displayNameRes())
        assertEquals(R.string.theme_light, ThemeMode.LIGHT.displayNameRes())
        assertEquals(R.string.theme_dark, ThemeMode.DARK.displayNameRes())
    }
}
