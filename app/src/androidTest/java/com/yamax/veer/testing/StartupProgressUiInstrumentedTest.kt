package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.StartupStage
import com.yamax.veer.ui.StartupProgressPanel
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.RuleChain

@RunWith(AndroidJUnit4::class)
class StartupProgressUiInstrumentedTest {

    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test(timeout = 30_000)
    fun startingStateShowsCurrentMilestoneAndProgress() {
        composeRule.setContent {
            VeerTheme {
                StartupProgressPanel(StartupStage.VALIDATING_CONFIG)
            }
        }

        composeRule.onNodeWithTag("startup_progress_panel").assertIsDisplayed()
        composeRule.onNodeWithTag("startup_progress_bar").assertIsDisplayed()
        composeRule.onNodeWithText("50%").assertIsDisplayed()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        composeRule.onNodeWithText(
            context.getString(
                R.string.startup_step,
                3,
                6,
                context.getString(R.string.startup_validating_config),
            ),
        ).assertIsDisplayed()
    }
}
