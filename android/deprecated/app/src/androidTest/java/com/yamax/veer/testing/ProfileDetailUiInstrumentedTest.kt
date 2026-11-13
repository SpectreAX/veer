package com.yamax.veer.testing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.ui.profile.ProfileDetailContent
import com.yamax.veer.ui.profile.ProfileDetailViewModel
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileDetailUiInstrumentedTest {
    private val composeRule = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun showsSelectionAndDispatchesNodeSwitch() {
        var selection: Pair<String, String>? = null
        val metadata = ProfileMetadata(
            id = ProfileId("test-profile"),
            displayName = "Test profile",
            source = ProfileSource.Base64Text(charCount = 10),
            importedAtMs = 1,
            lastUpdatedMs = 1,
            proxyCount = 2,
            groupCount = 1,
            ruleCount = 1,
            rawSizeBytes = 10,
            configHashSha256 = "test",
        )
        val group = ProfileDetailViewModel.ProxyGroupUi(
            name = "Streaming",
            type = "select",
            proxies = listOf("Japan 01", "Hong Kong 02"),
            selected = "Japan 01",
        )

        composeRule.setContent {
            VeerTheme {
                ProfileDetailContent(
                    state = ProfileDetailViewModel.UiState(
                        metadata = metadata,
                        proxyGroups = listOf(group),
                        isLoading = false,
                        vpnRunning = true,
                    ),
                    onBack = {},
                    onSelect = { groupName, proxyName -> selection = groupName to proxyName },
                )
            }
        }

        composeRule.onNodeWithTag("profile_detail_screen").assertIsDisplayed()
        composeRule.onNodeWithTag("profile_detail_groups").assertIsDisplayed()
        composeRule.onNodeWithText("Japan 01").assertIsDisplayed()
        composeRule.onNodeWithText("Hong Kong 02").performClick()
        composeRule.runOnIdle {
            assertEquals("Streaming" to "Hong Kong 02", selection)
        }
    }
}
