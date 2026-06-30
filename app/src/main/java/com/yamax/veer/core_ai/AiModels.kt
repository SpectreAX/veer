package com.yamax.veer.core_ai

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * Parsed intent returned by the LLM. Field names mirror the JSON schema the
 * system prompt enforces — keep them in sync with the prompt in [LlmClient].
 */
@Serializable
data class AiIntent(
    val action: Action,
    val target: String,
    @SerialName("match_type") val matchType: MatchType,
    @SerialName("proxy_group") val proxyGroup: String,
    @SerialName("reply_message") val replyMessage: String,
) {

    @Serializable
    enum class Action {
        @SerialName("add_rule") ADD_RULE,
        @SerialName("dns_change") DNS_CHANGE,
        @SerialName("diagnose") DIAGNOSE,
    }

    @Serializable
    enum class MatchType {
        @SerialName("DOMAIN") DOMAIN,
        @SerialName("DOMAIN-SUFFIX") DOMAIN_SUFFIX,
        @SerialName("DOMAIN-KEYWORD") DOMAIN_KEYWORD,
        @SerialName("GEOSITE") GEOSITE,
        @SerialName("GEOIP") GEOIP,
        @SerialName("IP-CIDR") IP_CIDR,
        @SerialName("NONE") NONE;

        /** Token used in the actual Mihomo rule line. */
        val ruleToken: String get() = when (this) {
            DOMAIN -> "DOMAIN"
            DOMAIN_SUFFIX -> "DOMAIN-SUFFIX"
            DOMAIN_KEYWORD -> "DOMAIN-KEYWORD"
            GEOSITE -> "GEOSITE"
            GEOIP -> "GEOIP"
            IP_CIDR -> "IP-CIDR"
            NONE -> "NONE"
        }
    }
}

// ---- DeepSeek chat/completions wire format -----------------------------------

@Serializable
data class ChatRequest(
    val model: String,
    val messages: List<ChatMessage>,
    val temperature: Double = 0.0,
    @SerialName("response_format") val responseFormat: ResponseFormat? = null,
    val stream: Boolean = false,
)

@Serializable
data class ChatMessage(
    val role: String, // "system" | "user" | "assistant"
    val content: String,
)

@Serializable
data class ResponseFormat(val type: String = "json_object")

@Serializable
data class ChatResponse(
    val id: String? = null,
    val model: String? = null,
    val choices: List<ChatChoice> = emptyList(),
    val usage: JsonObject? = null,
)

@Serializable
data class ChatChoice(
    val index: Int = 0,
    val message: ChatMessage,
    @SerialName("finish_reason") val finishReason: String? = null,
)
