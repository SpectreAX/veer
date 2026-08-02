package com.yamax.veer.core_ai

import android.content.ContextWrapper
import com.yamax.veer.core_mihomo.MihomoRepository
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AiControllerExecutionTest {

    private val context = object : ContextWrapper(null) {
        override fun getApplicationContext() = this
    }
    private val unavailableRepository = MihomoRepository(controllerPort = 1)

    @Test
    fun `clarification returns feedback without pretending to mutate configuration`() = runTest {
        val controller = AiController(context, mihomo = unavailableRepository)
        val intent = AiIntent(
            action = AiIntent.Action.CLARIFY,
            target = "user",
            matchType = AiIntent.MatchType.NONE,
            proxyGroup = "NONE",
            replyMessage = "请说明目标网站或节点地区。",
        )

        val outcome = controller.executeResolvedPlan(AiPlan.single(intent))

        assertTrue(outcome is AiController.Outcome.Success)
        outcome as AiController.Outcome.Success
        assertEquals("请说明目标网站或节点地区。", outcome.reply)
        assertEquals(null, outcome.ruleLine)
        assertEquals(null, outcome.reloadStatus)
    }

    @Test
    fun `unsupported dns operation fails before reporting success`() = runTest {
        val controller = AiController(context, mihomo = unavailableRepository)
        val intent = AiIntent(
            action = AiIntent.Action.DNS_CHANGE,
            target = "1.1.1.1",
            matchType = AiIntent.MatchType.NONE,
            proxyGroup = "NONE",
            replyMessage = "DNS 已修改。",
        )

        val outcome = controller.executeResolvedPlan(AiPlan.single(intent))

        assertTrue(outcome is AiController.Outcome.Failure)
        assertTrue(outcome.message.contains("暂不支持直接修改 DNS"))
        assertTrue(outcome.message.contains("计划未执行"))
    }

    @Test
    fun `committed rule feedback always includes effective exit direction`() {
        val intent = AiIntent(
            action = AiIntent.Action.ADD_RULE,
            target = "netflix",
            matchType = AiIntent.MatchType.GEOSITE,
            proxyGroup = "🇯🇵日本 02",
            replyMessage = "模型错误地声称已切换到香港。",
        )

        val reply = AiController.ruleResultReply(intent, changed = true)

        assertEquals("已将 netflix 的流量出口设为 🇯🇵日本 02。", reply)
        assertTrue("模型回复不得进入执行结果", !reply.contains("香港"))
    }

    @Test
    fun `clarification cannot be mixed with mutating operations`() = runTest {
        val controller = AiController(context, mihomo = unavailableRepository)
        val clarify = AiIntent(
            action = AiIntent.Action.CLARIFY,
            target = "user",
            matchType = AiIntent.MatchType.NONE,
            proxyGroup = "NONE",
            replyMessage = "需要澄清。",
        )
        val mutation = AiIntent(
            action = AiIntent.Action.ADD_RULE,
            target = "netflix",
            matchType = AiIntent.MatchType.GEOSITE,
            proxyGroup = "DIRECT",
            replyMessage = "已直连。",
        )
        val plan = AiPlan(
            schemaVersion = AiPlan.CURRENT_SCHEMA_VERSION,
            operations = listOf(clarify, mutation),
            replyMessage = "完成。",
        )

        val outcome = controller.executeResolvedPlan(plan)

        assertTrue(outcome is AiController.Outcome.Failure)
        assertTrue(outcome.message.contains("不能与配置修改混在同一计划"))
    }
}
