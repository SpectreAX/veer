package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.ui.connections.ConnectionsScreen
import com.yamax.veer.ui.connections.ConnectionsUiState
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConnectionsUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun showsConnectionAndConfirmsCloseAll() {
        val connection = MihomoRepository.ConnectionInfo(
            id = "test-connection",
            host = "stream.example.com",
            destinationIP = "203.0.113.42",
            network = "tcp",
            type = "HTTPS",
            chains = listOf("Japan 01"),
            rule = "Netflix",
            rulePayload = "",
            download = 1024,
            upload = 512,
            start = "",
        )
        composeRule.setContent {
            VeerTheme {
                ConnectionsScreen(
                    state = ConnectionsUiState(
                        connections = listOf(connection),
                        filteredConnections = listOf(connection),
                        loading = false,
                        running = true,
                    ),
                    onBack = {}, onSearch = {}, onSort = {}, onCloseConnection = {},
                    onCloseAll = {}, onDismissMessage = {},
                )
            }
        }

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        composeRule.onNodeWithTag("connections_screen").assertIsDisplayed()
        composeRule.onNodeWithTag("connections_list").assertIsDisplayed()
        composeRule.onNodeWithText("stream.example.com").assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.connections_close_all))
            .performClick()
        composeRule.onNodeWithText(context.getString(R.string.connections_close_all_title))
            .assertIsDisplayed()
    }
}
