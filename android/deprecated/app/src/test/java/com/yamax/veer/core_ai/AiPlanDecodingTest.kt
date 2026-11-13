package com.yamax.veer.core_ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AiPlanDecodingTest {

    private val client = LlmClient("test-key")

    @Test
    fun `decodes versioned multi-operation plan in order`() {
        val plan = client.decodePlan(
            """
            {
              "schema_version": 1,
              "operations": [
                {
                  "action": "add_rule",
                  "target": "netflix",
                  "match_type": "GEOSITE",
                  "proxy_group": "JP",
                  "selection_mode": "none",
                  "reply_message": "Netflix 已切换"
                },
                {
                  "action": "add_rule",
                  "target": "youtube",
                  "match_type": "GEOSITE",
                  "proxy_group": "US",
                  "selection_mode": "none",
                  "reply_message": "YouTube 已切换"
                }
              ],
              "reply_message": "两项分流已完成"
            }
            """.trimIndent(),
        )

        assertEquals(1, plan.schemaVersion)
        assertEquals(listOf("netflix", "youtube"), plan.operations.map { it.target })
        assertEquals("两项分流已完成", plan.replyMessage)
    }

    @Test
    fun `wraps legacy single-intent response as schema version one`() {
        val plan = client.decodePlan(
            """
            {
              "action": "diagnose",
              "target": "network",
              "match_type": "NONE",
              "proxy_group": "NONE",
              "selection_mode": "none",
              "reply_message": "开始诊断"
            }
            """.trimIndent(),
        )

        assertEquals(AiPlan.CURRENT_SCHEMA_VERSION, plan.schemaVersion)
        assertEquals(1, plan.operations.size)
        assertEquals(AiIntent.Action.DIAGNOSE, plan.operations.single().action)
    }

    @Test
    fun `rejects unsupported plan version`() {
        val error = runCatching {
            client.decodePlan(
                """
                {
                  "schema_version": 2,
                  "operations": [{
                    "action": "diagnose",
                    "target": "network",
                    "match_type": "NONE",
                    "proxy_group": "NONE",
                    "selection_mode": "none",
                    "reply_message": "开始诊断"
                  }],
                  "reply_message": "开始诊断"
                }
                """.trimIndent(),
            )
        }.exceptionOrNull()

        assertTrue(error is LlmException)
        assertTrue(error?.message.orEmpty().contains("schema_version=2"))
    }

    @Test
    fun `decodes non-mutating clarification plan`() {
        val plan = client.decodePlan(
            """
            {
              "schema_version": 1,
              "operations": [{
                "action": "clarify",
                "target": "user",
                "match_type": "NONE",
                "proxy_group": "NONE",
                "selection_mode": "none",
                "reply_message": "请说明目标网站或节点地区"
              }],
              "reply_message": "需要补充信息"
            }
            """.trimIndent(),
        )

        assertEquals(AiIntent.Action.CLARIFY, plan.operations.single().action)
    }
}
