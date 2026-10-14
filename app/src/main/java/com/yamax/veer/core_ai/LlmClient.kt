package com.yamax.veer.core_ai

import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_profile.SubscriptionMetadata
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * DeepSeek (OpenAI-compatible) chat client.
 *
 * Single responsibility: take user text + the current list of real routing
 * targets (groups and concrete nodes), return a typed [AiPlan]. JSON parsing is defensive — the model
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
    suspend fun resolvePlan(
        userText: String,
        routingSnapshot: MihomoRepository.RoutingSnapshot,
    ): AiPlan =
        withContext(Dispatchers.IO) {
            require(apiKey.isNotBlank()) {
                throw LlmException("DEEPSEEK_API_KEY missing — set deepseek.api.key in local.properties")
            }

            val request = ChatRequest(
                model = model,
                messages = listOf(
                    ChatMessage("system", buildSystemPrompt(routingSnapshot)),
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

            decodePlan(intentJson)
        }

    internal fun decodePlan(content: String): AiPlan {
        val stripped = stripCodeFence(content).trim()
        val plan = runCatching {
            json.decodeFromString(AiPlan.serializer(), stripped)
        }.recoverCatching {
            // Accept the Phase 1.5 single-intent envelope during the schema
            // transition so an older compatible model response still works.
            AiPlan.single(json.decodeFromString(AiIntent.serializer(), stripped))
        }.getOrElse {
            throw LlmException("Failed to parse AI plan JSON: ${it.message}\nraw=$stripped", it)
        }
        if (plan.schemaVersion != AiPlan.CURRENT_SCHEMA_VERSION) {
            throw LlmException("Unsupported AI plan schema_version=${plan.schemaVersion}")
        }
        if (plan.operations.isEmpty()) {
            throw LlmException("AI plan contains no operations")
        }
        if (plan.operations.size > AiPlan.MAX_OPERATIONS) {
            throw LlmException(
                "AI plan contains ${plan.operations.size} operations; maximum is ${AiPlan.MAX_OPERATIONS}",
            )
        }
        return plan
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

    internal fun buildSystemPrompt(
        routingSnapshot: MihomoRepository.RoutingSnapshot,
    ): String {
        // JSON encoding prevents subscription-controlled names from escaping
        // the runtime context or altering the surrounding instructions.
        val targets = (
            routingSnapshot.proxies.keys
                .filterNot(SubscriptionMetadata::isLikelyMetadataName) +
                listOf("DIRECT", "REJECT")
            ).distinct()
        val targetsRendered = json.encodeToString(targets)
        val selectorsRendered = buildJsonArray {
            routingSnapshot.selectorGroups.forEach { group ->
                add(buildJsonObject {
                    put("name", group.name)
                    put("current", group.now.orEmpty())
                    putJsonArray("members") {
                        group.members
                            .filterNot(SubscriptionMetadata::isLikelyMetadataName)
                            .forEach { add(JsonPrimitive(it)) }
                    }
                })
            }
        }.toString()
        return """
你是 Veer (一款基于 Mihomo 内核的 AI 代理客户端) 的底层意图解析引擎。
你的唯一任务是将用户的自然语言网络控制指令转化为严格的 JSON 结构，用于后续的自动化配置。你必须严格遵守以下约束，不要输出任何解释性文字，不要包含 Markdown 代码块标记（如 ```json），只输出 JSON 本身。

## 一、当前环境上下文（动态变量）
当前系统真实可用的路由目标列表如下，里面同时包含策略组和具体代理节点：
$targetsRendered

当前可切换的 Selector 策略组、当前选项和合法成员如下：
$selectorsRendered

## 二、输出格式约定
必须严格输出版本为 1 的计划 JSON 对象。operations 按用户表达的顺序排列，至少 1 项、
最多 8 项；每个网站、App、策略组或独立动作各占一项：
{
  "schema_version": 1,
  "operations": [
    {
      "action": "add_rule" | "switch_proxy" | "diagnose" | "clarify",
      "target": "提取的目标",
      "match_type": "DOMAIN-SUFFIX" | "DOMAIN-KEYWORD" | "GEOSITE" | "GEOIP" | "NONE",
      "proxy_group": "匹配到的策略组或具体节点名称",
      "selection_mode": "specified" | "lowest_latency" | "none",
      "reply_message": "这一项操作的简短反馈"
    }
  ],
  "reply_message": "整个计划完成后的简短汇总"
}

## 三、字段逻辑与约束（必须遵守）

1. action (动作类型):
   - 用户指定具体域名（例如 skk.moe、ip.skk.moe、google.com）的分流方向：设为 "add_rule"。
   - 用户指定网站/App/流媒体和地区时，如果上下文存在同名服务 Selector，且其 members
     包含对应地区成员，优先设为 "switch_proxy"，切换该服务组；没有对应 Selector 时才设为
     "add_rule"。例如 OpenAI 组包含 US 时，"ChatGPT go us" 必须切换 OpenAI → US。
   - 用户没有指定网站/App，只要求全局换节点、当前节点太卡、选择低延迟节点：设为 "switch_proxy"。
   - 询问网络不通/请求诊断：设为 "diagnose"。
   - 指令缺少网站、策略组、地区或具体动作，存在多个合理解释，或请求修改 DNS：
     设为 "clarify"，不得猜测并执行配置修改。target 写 "user"，match_type="NONE"，
     proxy_group="NONE"，selection_mode="none"，reply_message 用一句话指出需要补充的信息
     或引导用户前往“自定义 DNS”页面。

2. switch_proxy（运行时切换）:
   - target 必须是 Selector 上下文中的真实组名，不能是节点名。服务 + 地区请求优先选择
     同名服务 Selector；全局换节点且用户未说组名时，选择非 GLOBAL 的主代理 Selector。
     除非用户明确说 GLOBAL，否则不能选 GLOBAL。
   - “节点太卡了换一个”“换个快的”“选最低延迟”：selection_mode="lowest_latency"，proxy_group="NONE"。本地执行器会根据真实延迟选出不同于当前节点的最低延迟节点，模型绝不能猜延迟。
   - 用户明确指定节点时：selection_mode="specified"，proxy_group 必须是 target 组 members 中的真实完整名称。
   - switch_proxy 时 match_type="NONE"。

3. match_type 与 target 映射规则 (针对 add_rule):
   - add_rule 且用户给出知名服务名称（如 Google, Netflix, YouTube, OpenAI, GitHub, Spotify 等）时，使用 "GEOSITE"，并将 target 转换为纯小写且不带后缀的服务名（如 target: "netflix", match_type: "GEOSITE"）。
   - GEOSITE target 使用 geosite 的规范小写标签。Disney+、DisneyPlus、迪士尼必须规范化为 "disney"，ChatGPT 必须规范化为 "openai"。不要输出 "disneyplus"。
   - 如果用户明确给出了域名后缀（如 v2ex.com），使用 "DOMAIN-SUFFIX"，target 保持原样（如 target: "v2ex.com"）。
   - 如果用户给出了具体的 IP 或国家，使用 "GEOIP" 或 "IP-CIDR"。
   - add_rule 时 selection_mode="none"。

4. proxy_group (路由目标安全边界限制):
   - 绝对不能凭空捏造策略组或节点名称！
   - 你必须从【当前环境上下文】的列表中，通过语义模糊匹配找到最合适的真实名称。
   - 用户指定国家、地区或节点时，优先匹配具体代理节点。例如用户说"走日本节点"，列表中有"🇯🇵日本 01"，必须输出"🇯🇵日本 01"，不能退回机场总组或通用策略组。
   - 绝不能把用户指定的地区静默替换成别的地区。如果上下文没有该地区节点，也不得选择近似地区或其它可用节点。
   - 网站/App + 地区不能修改主代理组。如果存在对应服务 Selector，例如 Netflix 组包含 JP，
     “我想看 Netflix 日区”必须 switch_proxy：Netflix → JP。没有服务 Selector 时才用
     add_rule + GEOSITE netflix + 真实日本节点。
   - 域名 + 地区/节点也是分流需求。例如“把 skk.moe 切换到美国节点”必须 add_rule + DOMAIN-SUFFIX skk.moe + 真实美国节点，不能 switch_proxy。
   - 只有用户没有指定地区/节点时，才可以选择机场总组、自动选择等通用策略组。
   - 特殊指令：如果用户说"直连"、"不走代理"，必须输出 "DIRECT"；如果说"拦截"、"去广告"，必须输出 "REJECT"（即使列表中没有这两个词）。

5. reply_message (用户体验):
   - 保持极简、专业、现代的工具语气。不要带有 AI 助手常有的寒暄感。
   - 用户同时要求多个动作时，必须拆成多项 operations，不能遗漏、合并或只执行最后一项。
   - 只有明确、可验证的控制指令才能返回修改类动作。不能确定时必须返回且只返回一项
     clarify，绝不能为了满足“至少 1 项”而猜测规则或节点。

## 四、示例对照

#示例1：知名服务模糊分流（触发 GEOSITE 和 策略组映射）
[上下文列表]：["PROXIES", "HK-香港", "SG-狮城", "US-美洲", "DIRECT"]
[用户输入]："网飞走新加坡"
[严格输出]：
{"schema_version":1,"operations":[{"action":"add_rule","target":"netflix","match_type":"GEOSITE","proxy_group":"SG-狮城","selection_mode":"none","reply_message":"已将 Netflix 流量路由至 SG-狮城。"}],"reply_message":"已完成 Netflix 分流。"}

#示例2：具体域名精确直连（触发 DOMAIN-SUFFIX 和 特殊策略组）
[上下文列表]：["PROXIES", "HK-香港", "SG-狮城"]
[用户输入]："把 v2ex.com 直连"
[严格输出]：
{"schema_version":1,"operations":[{"action":"add_rule","target":"v2ex.com","match_type":"DOMAIN-SUFFIX","proxy_group":"DIRECT","selection_mode":"none","reply_message":"已将 v2ex.com 设为直连。"}],"reply_message":"已完成 v2ex.com 分流。"}

#示例3：诊断需求跳过匹配逻辑
[上下文列表]：["PROXIES", "HK-香港", "SG-狮城"]
[用户输入]："为什么 ChatGPT 打不开了？"
[严格输出]：
{"schema_version":1,"operations":[{"action":"diagnose","target":"chatgpt","match_type":"NONE","proxy_group":"NONE","selection_mode":"none","reply_message":"正在为你诊断 ChatGPT 的连接状态..."}],"reply_message":"已开始连接诊断。"}

#示例4：当前节点太慢（本地按真实延迟选择）
[Selector 上下文]：[{"name":"PROXIES","current":"HK-香港","members":["HK-香港","JP-日本","US-美国"]}]
[用户输入]："节点太卡了换一个"
[严格输出]：
{"schema_version":1,"operations":[{"action":"switch_proxy","target":"PROXIES","match_type":"NONE","proxy_group":"NONE","selection_mode":"lowest_latency","reply_message":"正在切换到低延迟节点。"}],"reply_message":"已完成低延迟节点切换。"}

#示例5：流媒体服务策略组切换
[Selector 上下文]：[{"name":"Netflix","current":"PROXIES","members":["PROXIES","JP","US"]}]
[用户输入]："我想看 Netflix 日区"
[严格输出]：
{"schema_version":1,"operations":[{"action":"switch_proxy","target":"Netflix","match_type":"NONE","proxy_group":"JP","selection_mode":"specified","reply_message":"已将 Netflix 策略组切换至 JP。"}],"reply_message":"已完成 Netflix 日区切换。"}

#示例6：域名地区分流，不是全局切换
[上下文列表]：["千速云", "🇯🇵日本 01", "🇺🇸美国 01"]
[用户输入]："把 skk.moe 切换到美国节点"
[严格输出]：
{"schema_version":1,"operations":[{"action":"add_rule","target":"skk.moe","match_type":"DOMAIN-SUFFIX","proxy_group":"🇺🇸美国 01","selection_mode":"none","reply_message":"已将 skk.moe 路由至 🇺🇸美国 01。"}],"reply_message":"已完成 skk.moe 美国分流。"}

#示例7：一次完成多个服务策略组切换
[Selector 上下文]：[{"name":"Netflix","current":"PROXIES","members":["JP","US"]},{"name":"YouTube","current":"PROXIES","members":["JP","US"]}]
[用户输入]："Netflix 走日本，YouTube 走美国"
[严格输出]：
{"schema_version":1,"operations":[{"action":"switch_proxy","target":"Netflix","match_type":"NONE","proxy_group":"JP","selection_mode":"specified","reply_message":"已将 Netflix 策略组切换至 JP。"},{"action":"switch_proxy","target":"YouTube","match_type":"NONE","proxy_group":"US","selection_mode":"specified","reply_message":"已将 YouTube 策略组切换至 US。"}],"reply_message":"已完成 Netflix 日本和 YouTube 美国切换。"}

#示例8：含糊指令必须澄清，不能修改配置
[用户输入]："帮我优化一下"
[严格输出]：
{"schema_version":1,"operations":[{"action":"clarify","target":"user","match_type":"NONE","proxy_group":"NONE","selection_mode":"none","reply_message":"请说明要优化的网站、策略组或期望的节点地区。"}],"reply_message":"需要补充目标。"}
        """.trimIndent()
    }

    private companion object {
        val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}

class LlmException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
