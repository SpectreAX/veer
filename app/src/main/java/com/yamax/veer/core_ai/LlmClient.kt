package com.yamax.veer.core_ai

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * DeepSeek (OpenAI-compatible) chat client.
 *
 * Single responsibility: take user text + the current list of real proxy group
 * names, return a typed [AiIntent]. JSON parsing is defensive — the model
 * sometimes returns a fenced code block even when `response_format=json_object`
 * is set, so we strip ``` fences before deserializing.
 */
class LlmClient(
    private val apiKey: String,
    private val baseUrl: String = "https://api.deepseek.com",
    private val model: String = "deepseek-chat",
) {

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    @Throws(LlmException::class)
    suspend fun resolveIntent(userText: String, proxyGroups: List<String>): AiIntent =
        withContext(Dispatchers.IO) {
            require(apiKey.isNotBlank()) {
                throw LlmException("DEEPSEEK_API_KEY missing — set deepseek.api.key in local.properties")
            }

            val request = ChatRequest(
                model = model,
                messages = listOf(
                    ChatMessage("system", buildSystemPrompt(proxyGroups)),
                    ChatMessage("user", userText),
                ),
                temperature = 0.0,
                responseFormat = ResponseFormat("json_object"),
            )

            val body = json.encodeToString(ChatRequest.serializer(), request)
                .toRequestBody(JSON_MEDIA)

            val http = Request.Builder()
                .url("$baseUrl/chat/completions")
                .header("Authorization", "Bearer $apiKey")
                .header("Accept", "application/json")
                .post(body)
                .build()

            val rawResponse = try {
                client.newCall(http).execute().use { res ->
                    val text = res.body?.string().orEmpty()
                    if (!res.isSuccessful) {
                        throw LlmException("DeepSeek HTTP ${res.code}: ${text.take(500)}")
                    }
                    text
                }
            } catch (e: IOException) {
                throw LlmException("DeepSeek network error: ${e.message}", e)
            }

            val parsed = runCatching {
                json.decodeFromString(ChatResponse.serializer(), rawResponse)
            }.getOrElse { throw LlmException("Malformed DeepSeek envelope: ${it.message}", it) }

            val intentJson = parsed.choices.firstOrNull()?.message?.content
                ?: throw LlmException("DeepSeek returned no choices")

            decodeIntent(intentJson)
        }

    private fun decodeIntent(content: String): AiIntent {
        val stripped = stripCodeFence(content).trim()
        return runCatching { json.decodeFromString(AiIntent.serializer(), stripped) }
            .getOrElse { throw LlmException("Failed to parse intent JSON: ${it.message}\nraw=$stripped", it) }
    }

    /** Removes ```json ... ``` fences the model occasionally wraps output in. */
    private fun stripCodeFence(s: String): String {
        val trimmed = s.trim()
        if (!trimmed.startsWith("```")) return trimmed
        val firstNewline = trimmed.indexOf('\n')
        if (firstNewline < 0) return trimmed
        val withoutOpening = trimmed.substring(firstNewline + 1)
        val closingFence = withoutOpening.lastIndexOf("```")
        return if (closingFence < 0) withoutOpening else withoutOpening.substring(0, closingFence)
    }

    private fun buildSystemPrompt(currentProxyGroups: List<String>): String {
        val groupsRendered = currentProxyGroups.joinToString(", ") { "\"$it\"" }
        return """
你是 Veer (一款基于 Mihomo 内核的 AI 代理客户端) 的底层意图解析引擎。
你的唯一任务是将用户的自然语言网络控制指令转化为严格的 JSON 结构，用于后续的自动化配置。你必须严格遵守以下约束，不要输出任何解释性文字，不要包含 Markdown 代码块标记（如 ```json），只输出 JSON 本身。

## 一、当前环境上下文（动态变量）
当前系统真实可用的策略组（Proxy Groups）列表如下：
[ $groupsRendered ]

## 二、输出格式约定
必须严格输出包含以下字段的 JSON 对象：
{
  "action": "add_rule" | "dns_change" | "diagnose",
  "target": "提取的目标",
  "match_type": "DOMAIN-SUFFIX" | "DOMAIN-KEYWORD" | "GEOSITE" | "GEOIP" | "NONE",
  "proxy_group": "匹配到的策略组名称",
  "reply_message": "给用户的简短反馈"
}

## 三、字段逻辑与约束（必须遵守）

1. action (动作类型):
   - 网站/App分流切换节点：设为 "add_rule"
   - 询问网络不通/请求诊断：设为 "diagnose"
   - 请求修改DNS：设为 "dns_change"

2. match_type 与 target 映射规则 (针对 add_rule):
   - 【优先级最高】如果用户给出知名服务名称（如 Google, Netflix, YouTube, OpenAI, GitHub, Spotify 等），你必须使用 "GEOSITE"，并将 target 转换为纯小写且不带后缀的服务名（如 target: "netflix", match_type: "GEOSITE"）。
   - 如果用户明确给出了域名后缀（如 v2ex.com），使用 "DOMAIN-SUFFIX"，target 保持原样（如 target: "v2ex.com"）。
   - 如果用户给出了具体的 IP 或国家，使用 "GEOIP" 或 "IP-CIDR"。

3. proxy_group (策略组安全边界限制):
   - 绝对不能凭空捏造策略组名称！
   - 你必须从【当前环境上下文】的列表中，通过语义模糊匹配找到最合适的真实名称。
   - 匹配示例：用户说"走台湾"，但列表中只有"TW-台湾"或"🇹🇼 Taiwan"，你必须输出列表里的真实名称。
   - 特殊指令：如果用户说"直连"、"不走代理"，必须输出 "DIRECT"；如果说"拦截"、"去广告"，必须输出 "REJECT"（即使列表中没有这两个词）。

4. reply_message (用户体验):
   - 保持极简、专业、现代的工具语气。不要带有 AI 助手常有的寒暄感。

## 四、示例对照

#示例1：知名服务模糊分流（触发 GEOSITE 和 策略组映射）
[上下文列表]：["PROXIES", "HK-香港", "SG-狮城", "US-美洲", "DIRECT"]
[用户输入]："网飞走新加坡"
[严格输出]：
{"action":"add_rule", "target":"netflix", "match_type":"GEOSITE", "proxy_group":"SG-狮城", "reply_message":"已将 Netflix 流量路由至 SG-狮城。"}

#示例2：具体域名精确直连（触发 DOMAIN-SUFFIX 和 特殊策略组）
[上下文列表]：["PROXIES", "HK-香港", "SG-狮城"]
[用户输入]："把 v2ex.com 直连"
[严格输出]：
{"action":"add_rule", "target":"v2ex.com", "match_type":"DOMAIN-SUFFIX", "proxy_group":"DIRECT", "reply_message":"已将 v2ex.com 设为直连。"}

#示例3：诊断需求跳过匹配逻辑
[上下文列表]：["PROXIES", "HK-香港", "SG-狮城"]
[用户输入]："为什么 ChatGPT 打不开了？"
[严格输出]：
{"action":"diagnose", "target":"chatgpt", "match_type":"NONE", "proxy_group":"NONE", "reply_message":"正在为你诊断 ChatGPT 的连接状态..."}
        """.trimIndent()
    }

    private companion object {
        val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}

class LlmException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
