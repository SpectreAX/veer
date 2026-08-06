package com.yamax.veer.testing

import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.data.AiHistoryEntry
import com.yamax.veer.data.AiHistoryMutation
import com.yamax.veer.data.AiHistoryRuleStore
import com.yamax.veer.data.AiHistorySource
import com.yamax.veer.data.AiHistoryStatus
import com.yamax.veer.ui.ai.AiHistorySection
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AiHistoryUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun dispatchesReplayAndUndoForActiveProfile() {
        val entry = AiHistoryEntry(
            id = "test",
            profileId = "active",
            prompt = "Netflix go jp",
            source = AiHistorySource.LOCAL,
            status = AiHistoryStatus.SUCCESS,
            timestampMs = 1_700_000_000_000,
            summary = "Netflix exits through Japan.",
            mutation = AiHistoryMutation(
                rulesBefore = AiHistoryRuleStore(emptyList(), emptyList()),
                rulesAfter = AiHistoryRuleStore(
                    enabled = listOf("GEOSITE,netflix,JP"),
                    disabled = emptyList(),
                ),
            ),
        )
        var replayed: AiHistoryEntry? = null
        var undone: AiHistoryEntry? = null

        composeRule.setContent {
            VeerTheme {
                AiHistorySection(
                    entries = listOf(entry),
                    activeProfileId = "active",
                    busy = false,
                    onReplay = { replayed = it },
                    onUndo = { undone = it },
                    modifier = Modifier.padding(VeerSpacing.lg),
                )
            }
        }

        composeRule.onNodeWithTag("ai_history").assertIsDisplayed()
        val replayLabel = InstrumentationRegistry.getInstrumentation()
            .targetContext.getString(R.string.ai_history_replay)
        composeRule.onNodeWithText(replayLabel).performClick()
        composeRule.onNodeWithTag("ai_history_undo").performClick()
        composeRule.runOnIdle {
            assertEquals(entry, replayed)
            assertEquals(entry, undone)
        }
    }
}
