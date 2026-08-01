package com.yamax.veer.core_ai

import com.yamax.veer.core_mihomo.MihomoRepository
import org.junit.Assert.assertTrue
import org.junit.Test

class LlmSystemPromptTest {

    @Test
    fun `prompt distinguishes global latency switching from service routing`() {
        val states = listOf(
            MihomoRepository.ProxyState(
                name = "千速云",
                type = "Selector",
                now = "🇭🇰香港 01",
                members = listOf("🇭🇰香港 01", "🇯🇵日本 01"),
                delayMs = null,
            ),
            MihomoRepository.ProxyState("🇭🇰香港 01", "Vless", null, emptyList(), 30),
            MihomoRepository.ProxyState("🇯🇵日本 01", "Vless", null, emptyList(), 60),
        )
        val snapshot = MihomoRepository.RoutingSnapshot(states.associateBy { it.name })

        val prompt = LlmClient("test-key").buildSystemPrompt(snapshot)

        assertTrue(prompt.contains("节点太卡了换一个"))
        assertTrue(prompt.contains("\"selection_mode\":\"lowest_latency\""))
        assertTrue(prompt.contains("我想看 Netflix 日区"))
        assertTrue(prompt.contains("\"target\":\"netflix\""))
        assertTrue(prompt.contains("把 skk.moe 切换到美国节点"))
        assertTrue(prompt.contains("\"target\":\"skk.moe\""))
        assertTrue(prompt.contains("\"match_type\":\"DOMAIN-SUFFIX\""))
        assertTrue(prompt.contains("🇯🇵日本 01"))
        assertTrue(prompt.contains("\"current\":\"🇭🇰香港 01\""))
        assertTrue(prompt.contains("\"schema_version\":1"))
        assertTrue(prompt.contains("Netflix 走日本，YouTube 走美国"))
        assertTrue(prompt.contains("\"target\":\"youtube\""))
        assertTrue(prompt.contains("DisneyPlus、迪士尼必须规范化为 \"disney\""))
        assertTrue(prompt.contains("绝不能把用户指定的地区静默替换成别的地区"))
        assertTrue(prompt.contains("\"action\":\"clarify\""))
        assertTrue(prompt.contains("不能确定时必须返回且只返回一项"))
        assertTrue(prompt.contains("请求修改 DNS"))
    }

    @Test
    fun `geosite aliases canonicalize known names and preserve safe tags`() {
        assertTrue(AiController.canonicalGeositeTarget("DisneyPlus") == "disney")
        assertTrue(AiController.canonicalGeositeTarget("ChatGPT") == "openai")
        assertTrue(AiController.canonicalGeositeTarget("telegram") == "telegram")
        assertTrue(AiController.canonicalGeositeTarget("../unsafe") == null)
    }
}
