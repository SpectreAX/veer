package com.yamax.veer.ui.rules

import com.yamax.veer.R
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.uiText
import java.util.Locale

/** User-facing wording for a persisted Mihomo rule. */
internal data class AiRulePresentation(
    val sourceLabel: UiText,
    val destinationLabel: UiText,
    val routeSummary: UiText,
    val matchDescription: UiText,
)

internal fun aiRulePresentation(rule: ManagedAiRule): AiRulePresentation {
    val matchType = rule.matchType.trim().uppercase(Locale.ROOT)
    val source = when (matchType) {
        "GEOSITE" -> serviceDisplayName(rule.target)
        else -> UiText.Verbatim(rule.target)
    }
    val destination = policyDisplayName(rule.policy)
    val matchDescription = when (matchType) {
        "GEOSITE" -> uiText(R.string.rules_match_geosite, rule.target)
        "DOMAIN" -> uiText(R.string.rules_match_domain, rule.target)
        "DOMAIN-SUFFIX" -> uiText(R.string.rules_match_domain_suffix, rule.target)
        "DOMAIN-KEYWORD" -> uiText(R.string.rules_match_domain_keyword, rule.target)
        "IP-CIDR", "IP-CIDR6" -> uiText(R.string.rules_match_ip_cidr, rule.target)
        "GEOIP" -> uiText(R.string.rules_match_geoip, rule.target)
        "RULE-SET" -> uiText(R.string.rules_match_rule_set, rule.target)
        else -> uiText(R.string.rules_match_other, matchType, rule.target)
    }
    return AiRulePresentation(
        sourceLabel = source,
        destinationLabel = destination,
        routeSummary = uiText(R.string.rules_route_summary, source, destination),
        matchDescription = matchDescription,
    )
}

private fun serviceDisplayName(target: String): UiText = when (target.trim().lowercase()) {
    "netflix" -> UiText.Verbatim("Netflix")
    "youtube" -> UiText.Verbatim("YouTube")
    "google" -> UiText.Verbatim("Google")
    "openai" -> UiText.Verbatim("OpenAI / ChatGPT")
    "github" -> UiText.Verbatim("GitHub")
    "spotify" -> UiText.Verbatim("Spotify")
    "disney" -> UiText.Verbatim("Disney+")
    "telegram" -> UiText.Verbatim("Telegram")
    "tiktok" -> UiText.Verbatim("TikTok")
    "twitter" -> UiText.Verbatim("X / Twitter")
    "facebook" -> UiText.Verbatim("Facebook")
    "instagram" -> UiText.Verbatim("Instagram")
    "bilibili" -> uiText(R.string.rules_service_bilibili)
    else -> UiText.Verbatim(target)
}

private fun policyDisplayName(policy: String): UiText = when (policy.trim().uppercase(Locale.ROOT)) {
    "DIRECT" -> uiText(R.string.rules_policy_direct)
    "REJECT", "REJECT-DROP" -> uiText(R.string.rules_policy_block)
    "HK", "HONG KONG" -> uiText(R.string.rules_policy_hong_kong, policy.trim())
    "JP", "JAPAN" -> uiText(R.string.rules_policy_japan, policy.trim())
    "US", "USA", "UNITED STATES" -> uiText(R.string.rules_policy_united_states, policy.trim())
    "SG", "SINGAPORE" -> uiText(R.string.rules_policy_singapore, policy.trim())
    "TW", "TAIWAN" -> uiText(R.string.rules_policy_taiwan, policy.trim())
    else -> UiText.Verbatim(policy)
}
