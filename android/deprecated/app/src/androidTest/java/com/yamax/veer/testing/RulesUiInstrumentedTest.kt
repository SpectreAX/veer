package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.rules.RulesScreen
import com.yamax.veer.ui.rules.RulesUiState
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RulesUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun rendersLocalizedDirectionAndOpensExitPicker() {
        val rule = ManagedAiRule(
            id = "test-rule",
            raw = "GEOSITE,netflix,HK",
            matchType = "GEOSITE",
            target = "netflix",
            policy = "HK",
            enabled = true,
            policyAvailable = true,
            loadedInMaterializedConfig = true,
        )
        composeRule.setContent {
            VeerTheme {
                RulesScreen(
                    state = RulesUiState(
                        profileName = "Test profile",
                        profileId = "test-profile",
                        rules = listOf(rule),
                        availablePolicies = listOf("HK", "JP"),
                        engineRunning = true,
                        loading = false,
                    ),
                    onBack = {},
                    onRefresh = {},
                    onReapply = {},
                    onEnabledChange = { _, _ -> },
                    onDelete = {},
                    onRebind = { _, _ -> },
                    onDismissMessage = {},
                )
            }
        }

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val destination = context.getString(R.string.rules_policy_hong_kong, "HK")
        val route = context.getString(R.string.rules_route_summary, "Netflix", destination)
        val match = context.getString(R.string.rules_match_geosite, "netflix")

        composeRule.onNodeWithTag("ai_rule_list").assertIsDisplayed()
        composeRule.onNodeWithText(route).assertIsDisplayed()
        composeRule.onNodeWithText(match).assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.rules_health_running))
            .assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.rules_change_exit))
            .performScrollTo()
            .performClick()
        composeRule.onNodeWithText(context.getString(R.string.rules_select_exit))
            .assertIsDisplayed()
        composeRule.onNodeWithText("JP").assertIsDisplayed()
    }
}
