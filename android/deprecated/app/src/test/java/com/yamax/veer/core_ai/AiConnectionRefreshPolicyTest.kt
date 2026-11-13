package com.yamax.veer.core_ai

import com.yamax.veer.core_mihomo.MihomoRepository
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AiConnectionRefreshPolicyTest {

    @Test
    fun `openai geosite refreshes existing rule and known service domains`() {
        val intent = rule("openai", AiIntent.MatchType.GEOSITE)

        assertTrue(
            AiConnectionRefreshPolicy.shouldClose(
                intent,
                connection(host = "ios.chat.openai.com", rulePayload = "openai"),
            ),
        )
        assertTrue(
            AiConnectionRefreshPolicy.shouldClose(
                intent,
                connection(host = "cdn.oaistatic.com"),
            ),
        )
        assertTrue(
            AiConnectionRefreshPolicy.shouldClose(
                intent,
                connection(host = "chatgpt.com"),
            ),
        )
    }

    @Test
    fun `openai refresh does not close unrelated connections`() {
        assertFalse(
            AiConnectionRefreshPolicy.shouldClose(
                rule("openai", AiIntent.MatchType.GEOSITE),
                connection(host = "example.com", rulePayload = "google"),
            ),
        )
    }

    @Test
    fun `domain suffix refresh includes subdomains but not lookalikes`() {
        val intent = rule("example.com", AiIntent.MatchType.DOMAIN_SUFFIX)

        assertTrue(
            AiConnectionRefreshPolicy.shouldClose(intent, connection(host = "api.example.com")),
        )
        assertFalse(
            AiConnectionRefreshPolicy.shouldClose(intent, connection(host = "badexample.com")),
        )
    }

    @Test
    fun `non rule operations never close connections`() {
        val intent = rule("openai", AiIntent.MatchType.GEOSITE).copy(
            action = AiIntent.Action.DIAGNOSE,
        )

        assertFalse(
            AiConnectionRefreshPolicy.shouldClose(intent, connection(host = "chatgpt.com")),
        )
    }

    private fun rule(target: String, matchType: AiIntent.MatchType) = AiIntent(
        action = AiIntent.Action.ADD_RULE,
        target = target,
        matchType = matchType,
        proxyGroup = "US",
        replyMessage = "done",
    )

    private fun connection(
        host: String,
        rulePayload: String = "",
    ) = MihomoRepository.ConnectionInfo(
        id = "id-$host",
        host = host,
        destinationIP = "203.0.113.1",
        network = "tcp",
        type = "HTTPS",
        chains = listOf("old-node"),
        rule = "GeoSite",
        rulePayload = rulePayload,
        download = 0,
        upload = 0,
        start = "",
    )
}
