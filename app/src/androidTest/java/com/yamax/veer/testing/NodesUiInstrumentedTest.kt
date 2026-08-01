package com.yamax.veer.testing

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.ui.nodes.NodeFilter
import com.yamax.veer.ui.nodes.NodeSortMode
import com.yamax.veer.ui.nodes.NodeUi
import com.yamax.veer.ui.nodes.NodesScreen
import com.yamax.veer.ui.nodes.NodesUiState
import com.yamax.veer.ui.nodes.ProxyGroupUi
import com.yamax.veer.ui.nodes.filterAndSortGroups
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NodesUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun rendersLocalizedControlsAndHidesUnavailableNodes() {
        val group = ProxyGroupUi(
            name = "PROXY",
            type = "Selector",
            selected = "Tokyo A",
            selectable = true,
            nodes = listOf(
                NodeUi("Tokyo A", "VLESS", "JP", 42, true, true),
                NodeUi("Hong Kong B", "Trojan", "HK", 250, true, false),
                NodeUi("Offline C", "Shadowsocks", "US", 65_535, false, false),
            ),
        )
        var filter by mutableStateOf(NodeFilter())
        composeRule.setContent {
            VeerTheme {
                NodesScreen(
                    state = NodesUiState(
                        groups = listOf(group),
                        running = true,
                        loading = false,
                    ),
                    filter = filter,
                    availableRegions = listOf("HK", "JP", "US"),
                    filteredGroups = filterAndSortGroups(listOf(group), filter),
                    onBack = {},
                    onRefresh = {},
                    onProbeAll = {},
                    onSelect = { _, _ -> },
                    onAutoSelect = { _ -> },
                    onProbe = { _ -> },
                    onDismissMessage = {},
                    onUpdateSortMode = { filter = filter.copy(sortMode = it) },
                    onUpdateRegionFilter = { filter = filter.copy(regionFilter = it) },
                    onToggleHideUnavailable = {
                        filter = filter.copy(hideUnavailable = !filter.hideUnavailable)
                    },
                )
            }
        }

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        composeRule.onNodeWithText(context.getString(R.string.nodes_title)).assertIsDisplayed()
        composeRule.onNodeWithText("[JP] Tokyo A").assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.nodes_delay_ms, 42))
            .assertIsDisplayed()
        composeRule.onNodeWithTag("node_sort_delay").performClick()
        composeRule.runOnIdle { check(filter.sortMode == NodeSortMode.DELAY_ASC) }
        composeRule.onNodeWithTag("node_hide_unavailable")
            .performScrollTo()
            .performClick()
        composeRule.runOnIdle { check(filter.hideUnavailable) }
        composeRule.onAllNodesWithText("Offline C").assertCountEquals(0)
        composeRule.onNodeWithTag("probe_all_nodes").assertIsDisplayed()
    }
}
