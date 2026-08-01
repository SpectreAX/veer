package com.yamax.veer.ui.rules

import com.yamax.veer.R
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.UiText
import org.junit.Assert.assertEquals
import org.junit.Test

class AiRulePresentationTest {

    @Test
    fun `Netflix Hong Kong rule makes traffic direction explicit`() {
        val presentation = aiRulePresentation(rule("GEOSITE", "netflix", "HK"))

        val route = presentation.routeSummary.asResource(R.string.rules_route_summary)
        assertEquals(UiText.Verbatim("Netflix"), route.arguments[0])
        assertEquals(
            presentation.destinationLabel,
            route.arguments[1],
        )
        val destination = presentation.destinationLabel.asResource(R.string.rules_policy_hong_kong)
        assertEquals(listOf("HK"), destination.arguments)
        val match = presentation.matchDescription.asResource(R.string.rules_match_geosite)
        assertEquals(listOf("netflix"), match.arguments)
    }

    @Test
    fun `concrete node name is preserved as the exit`() {
        val presentation = aiRulePresentation(
            rule("GEOSITE", "netflix", "🇭🇰 香港 01"),
        )

        val route = presentation.routeSummary.asResource(R.string.rules_route_summary)
        assertEquals(UiText.Verbatim("Netflix"), route.arguments[0])
        assertEquals(UiText.Verbatim("🇭🇰 香港 01"), route.arguments[1])
        assertEquals(UiText.Verbatim("🇭🇰 香港 01"), presentation.destinationLabel)
    }

    @Test
    fun `domain direct rule explains bypass direction`() {
        val presentation = aiRulePresentation(
            rule("DOMAIN-SUFFIX", "example.com", "DIRECT"),
        )

        val route = presentation.routeSummary.asResource(R.string.rules_route_summary)
        assertEquals(UiText.Verbatim("example.com"), route.arguments[0])
        assertEquals(
            R.string.rules_policy_direct,
            (route.arguments[1] as UiText.Resource).resourceId,
        )
        presentation.matchDescription.asResource(R.string.rules_match_domain_suffix)
    }

    private fun rule(matchType: String, target: String, policy: String) = ManagedAiRule(
        id = "test-rule",
        raw = "$matchType,$target,$policy",
        matchType = matchType,
        target = target,
        policy = policy,
        enabled = true,
        policyAvailable = true,
        loadedInMaterializedConfig = true,
    )

    private fun UiText.asResource(expectedId: Int): UiText.Resource {
        val resource = this as UiText.Resource
        assertEquals(expectedId, resource.resourceId)
        return resource
    }
}
