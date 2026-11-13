package com.yamax.veer.core_ai

import com.yamax.veer.core_mihomo.MihomoRepository

/**
 * Selects only established connections that can be affected by a newly
 * committed AI rule. Mihomo keeps existing TCP/QUIC sessions on their old
 * chain after a rule-table reload, so those sessions must reconnect before
 * the requested exit direction is observable.
 */
internal object AiConnectionRefreshPolicy {

    fun shouldClose(
        intent: AiIntent,
        connection: MihomoRepository.ConnectionInfo,
    ): Boolean {
        if (intent.action != AiIntent.Action.ADD_RULE) return false
        val host = connection.host.trimEnd('.').lowercase()
        val target = intent.target.trimEnd('.').lowercase()
        val rulePayload = connection.rulePayload.trim().lowercase()
        if (target.isEmpty()) return false

        return when (intent.matchType) {
            AiIntent.MatchType.DOMAIN -> host == target
            AiIntent.MatchType.DOMAIN_SUFFIX ->
                host == target || host.endsWith(".$target")
            AiIntent.MatchType.DOMAIN_KEYWORD -> target in host
            AiIntent.MatchType.GEOSITE ->
                rulePayload == target || serviceDomains(target).any { domain ->
                    host == domain || host.endsWith(".$domain")
                }
            AiIntent.MatchType.GEOIP,
            AiIntent.MatchType.IP_CIDR -> rulePayload.equals(target, ignoreCase = true)
            AiIntent.MatchType.NONE -> false
        }
    }

    private fun serviceDomains(target: String): Set<String> =
        SERVICE_DOMAINS[target].orEmpty()

    private val SERVICE_DOMAINS = mapOf(
        "openai" to setOf(
            "chatgpt.com",
            "openai.com",
            "oaistatic.com",
            "oaiusercontent.com",
        ),
        "netflix" to setOf("netflix.com", "netflix.net", "nflxvideo.net"),
        "youtube" to setOf("youtube.com", "youtu.be", "googlevideo.com", "ytimg.com"),
        "google" to setOf("google.com", "googleapis.com", "gstatic.com"),
        "github" to setOf("github.com", "githubusercontent.com", "githubassets.com"),
        "spotify" to setOf("spotify.com", "scdn.co", "spotifycdn.com"),
        "disney" to setOf("disneyplus.com", "disney-plus.net", "bamgrid.com"),
    )
}
