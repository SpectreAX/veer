package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yamax.veer.ui.navigation.VeerBottomBar
import com.yamax.veer.ui.navigation.VeerTopLevelDestination
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BottomNavigationUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun exposesFiveDestinationsAndDispatchesSelection() {
        var selected = VeerTopLevelDestination.HOME
        composeRule.setContent {
            VeerTheme {
                VeerBottomBar(
                    selected = selected,
                    onSelect = { selected = it },
                )
            }
        }

        composeRule.onNodeWithTag("bottom_navigation").assertIsDisplayed()
        VeerTopLevelDestination.entries.forEach { destination ->
            composeRule.onNodeWithTag("bottom_nav_${destination.name}").assertIsDisplayed()
        }
        composeRule.onNodeWithTag("bottom_nav_HOME").assertIsSelected()
        composeRule.onNodeWithTag("bottom_nav_RULES").performClick()
        composeRule.runOnIdle {
            assertEquals(VeerTopLevelDestination.RULES, selected)
        }
    }
}
