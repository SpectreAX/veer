package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yamax.veer.ui.logs.LogSource
import com.yamax.veer.ui.logs.LogViewerScreen
import com.yamax.veer.ui.logs.LogViewerUiState
import com.yamax.veer.ui.logs.ViewerLogLevel
import com.yamax.veer.ui.logs.ViewerLogLine
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LogViewerUiInstrumentedTest {

    private val composeRule = createComposeRule()
    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun displaysStructuredLogAndOffersFiltersAndActions() {
        composeRule.setContent {
            VeerTheme {
                LogViewerScreen(
                    state = LogViewerUiState(
                        lines = listOf(
                            ViewerLogLine(
                                id = "test",
                                time = "12:34:56.789",
                                source = LogSource.CORE,
                                level = ViewerLogLevel.WARN,
                                category = "watchdog",
                                message = "probe failed",
                            ),
                        ),
                    ),
                    onBack = {},
                    onQueryChange = {},
                    onSourceChange = {},
                    onLevelChange = {},
                    onTogglePaused = {},
                    onRefresh = {},
                    onCopy = {},
                    onExport = {},
                )
            }
        }

        composeRule.onNodeWithTag("log_viewer").assertIsDisplayed()
        composeRule.onNodeWithTag("log_list").assertIsDisplayed()
        composeRule.onNodeWithText("probe failed").assertIsDisplayed()
        composeRule.onNodeWithText("Veercore").performClick()
        composeRule.onNodeWithText("Warn").assertIsDisplayed()
        composeRule.onNodeWithText("复制").assertIsDisplayed()
        composeRule.onNodeWithText("导出").assertIsDisplayed()
    }
}
