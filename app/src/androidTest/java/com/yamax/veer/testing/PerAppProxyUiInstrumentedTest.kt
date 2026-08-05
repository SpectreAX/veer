package com.yamax.veer.testing

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.ui.perapp.InstalledAppEntry
import com.yamax.veer.ui.perapp.PerAppProxyScreen
import com.yamax.veer.ui.perapp.PerAppProxyUiState
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PerAppProxyUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun selectsAppAndSavesOnlySelectedMode() {
        val packageName = "com.example.streaming"
        var state by mutableStateOf(
            PerAppProxyUiState(
                loading = false,
                apps = listOf(
                    InstalledAppEntry(
                        label = "Streaming",
                        packageName = packageName,
                        isSystemApp = false,
                    ),
                ),
            ),
        )
        var savedWhileRunning: Boolean? = null

        composeRule.setContent {
            VeerTheme {
                PerAppProxyScreen(
                    state = state,
                    runtimeRunning = true,
                    onBack = {},
                    onRetry = {},
                    onModeChange = { state = state.copy(mode = it) },
                    onTogglePackage = { selectedPackage ->
                        state = state.copy(
                            selectedPackages = state.selectedPackages.toMutableSet().apply {
                                if (!add(selectedPackage)) remove(selectedPackage)
                            },
                        )
                    },
                    onSelectVisible = {},
                    onClearSelection = {},
                    onSave = { savedWhileRunning = it },
                    onDismissMessage = {},
                )
            }
        }

        composeRule.onNodeWithTag("per_app_screen").assertIsDisplayed()
        composeRule.onNodeWithTag("per_app_mode_ONLY_SELECTED").performScrollTo().performClick()
        composeRule.onNodeWithTag("per_app_$packageName").performScrollTo().performClick()
        composeRule.runOnIdle {
            assertEquals(PerAppProxyMode.ONLY_SELECTED, state.mode)
            assertTrue(packageName in state.selectedPackages)
            assertTrue(state.canSave)
        }
        composeRule.onNodeWithTag("save_per_app_policy").performScrollTo().performClick()
        composeRule.runOnIdle { assertEquals(true, savedWhileRunning) }
    }
}
