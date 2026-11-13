package com.yamax.veer.testing

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.core_profile.DnsOverrideValidator
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.ui.dns.DnsSettingsScreen
import com.yamax.veer.ui.dns.DnsSettingsUiState
import com.yamax.veer.ui.theme.VeerTheme
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DnsSettingsUiInstrumentedTest {
    private val composeRule = createComposeRule()
    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(InteractiveComposeDeviceRule())
        .around(composeRule)

    @Test
    fun switchesToCustomDnsAndShowsReconnectAction() {
        var state by mutableStateOf(
            DnsSettingsUiState(
                loading = false,
                profileId = ProfileId("test"),
                profileName = "Test profile",
                isActiveProfile = true,
                runtimeState = EngineState.Running,
            ),
        )
        composeRule.setContent {
            VeerTheme {
                DnsSettingsScreen(
                    state = state,
                    onBack = {},
                    onModeChange = { mode ->
                        val policy = if (mode == DnsOverrideMode.CUSTOM) {
                            DnsOverridePolicy.recommendedCustom()
                        } else {
                            DnsOverridePolicy()
                        }
                        state = state.copy(
                            policy = policy,
                            validationIssues = DnsOverrideValidator.validate(policy),
                        )
                    },
                    onIpv6Change = { state = state.copy(policy = state.policy.copy(ipv6 = it)) },
                    onEnhancedModeChange = {
                        state = state.copy(policy = state.policy.copy(enhancedMode = it))
                    },
                    onDefaultNameserversChange = {},
                    onNameserversChange = {},
                    onFallbackNameserversChange = {},
                    onSave = {},
                    onDismissMessage = {},
                )
            }
        }

        composeRule.onNodeWithTag("dns_settings_screen").assertIsDisplayed()
        composeRule.onNodeWithTag("dns_custom_mode").performClick()
        composeRule.runOnIdle {
            check(state.policy.mode == DnsOverrideMode.CUSTOM)
        }
        composeRule.onNodeWithTag("dns_bootstrap_input").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("dns_primary_input").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("dns_redir_host_mode").performScrollTo().performClick()
        composeRule.runOnIdle {
            check(state.policy.enhancedMode == DnsEnhancedMode.REDIR_HOST)
        }
        composeRule.onNodeWithTag("save_dns_settings").performScrollTo().assertIsDisplayed()
        val reconnectLabel = InstrumentationRegistry.getInstrumentation()
            .targetContext.getString(R.string.dns_save_reconnect)
        composeRule.onNodeWithText(reconnectLabel).performScrollTo().assertIsDisplayed()
    }
}
