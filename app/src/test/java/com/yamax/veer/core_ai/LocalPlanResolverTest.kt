package com.yamax.veer.core_ai

import com.yamax.veer.core_mihomo.MihomoRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalPlanResolverTest {

    @Test
    fun `direct command creates ordered rules for every explicit domain`() {
        val plan = LocalPlanResolver.resolve(
            "让 example.com 和 api.example.org 直连",
            snapshot(),
        )!!

        assertEquals(listOf("example.com", "api.example.org"), plan.operations.map { it.target })
        assertEquals(listOf("DIRECT", "DIRECT"), plan.operations.map { it.proxyGroup })
        assertEquals(AiIntent.MatchType.DOMAIN_SUFFIX, plan.operations.first().matchType)
    }

    @Test
    fun `reject command is parsed without an LLM`() {
        val operation = LocalPlanResolver.resolve(
            "屏蔽 ads.example.com",
            snapshot(),
        )!!.operations.single()

        assertEquals("ads.example.com", operation.target)
        assertEquals("REJECT", operation.proxyGroup)
    }

    @Test
    fun `domain immediately followed by Chinese command is recognized`() {
        val operation = LocalPlanResolver.resolve(
            "local-test.example直连",
            snapshot(),
        )!!.operations.single()

        assertEquals("local-test.example", operation.target)
        assertEquals("DIRECT", operation.proxyGroup)
    }

    @Test
    fun `service-looking domain remains one explicit domain target`() {
        val operation = LocalPlanResolver.resolve(
            "netflix.com go HK",
            snapshot(),
        )!!.operations.single()

        assertEquals("netflix.com", operation.target)
        assertEquals(AiIntent.MatchType.DOMAIN_SUFFIX, operation.matchType)
        assertEquals("🇭🇰香港 02", operation.proxyGroup)
    }

    @Test
    fun `mixed service and domain direct command keeps both explicit targets`() {
        val plan = LocalPlanResolver.resolve(
            "Netflix 和 example.com 直连",
            snapshot(),
        )!!

        assertEquals(listOf("example.com", "netflix"), plan.operations.map { it.target })
        assertEquals(
            listOf(AiIntent.MatchType.DOMAIN_SUFFIX, AiIntent.MatchType.GEOSITE),
            plan.operations.map { it.matchType },
        )
    }

    @Test
    fun `diagnosis request is resolved locally`() {
        val operation = LocalPlanResolver.resolve(
            "为什么 ChatGPT 打不开",
            snapshot(),
        )!!.operations.single()

        assertEquals(AiIntent.Action.DIAGNOSE, operation.action)
        assertEquals("openai", operation.target)
    }

    @Test
    fun `slow node command selects preferred real selector`() {
        val operation = LocalPlanResolver.resolve(
            "节点太卡了换一个",
            snapshot(),
            preferredSelector = "千速云",
        )!!.operations.single()

        assertEquals(AiIntent.Action.SWITCH_PROXY, operation.action)
        assertEquals("千速云", operation.target)
        assertEquals(AiIntent.SelectionMode.LOWEST_LATENCY, operation.selectionMode)
    }

    @Test
    fun `service region command picks lowest-delay explicitly healthy node`() {
        val operation = LocalPlanResolver.resolve(
            "Netflix走香港",
            snapshot(),
        )!!.operations.single()

        assertEquals("netflix", operation.target)
        assertEquals(AiIntent.MatchType.GEOSITE, operation.matchType)
        assertEquals("🇭🇰香港 02", operation.proxyGroup)
    }

    @Test
    fun `short English service command is resolved locally`() {
        val operation = LocalPlanResolver.resolve(
            "Netflix go HK",
            snapshot(),
        )!!.operations.single()

        assertEquals("netflix", operation.target)
        assertEquals("🇭🇰香港 02", operation.proxyGroup)
    }

    @Test
    fun `multiple services can share one regional route without LLM`() {
        val plan = LocalPlanResolver.resolve(
            "Netflix 和 YouTube 都走香港",
            snapshot(),
        )!!

        assertEquals(listOf("netflix", "youtube"), plan.operations.map { it.target })
        assertEquals(
            listOf("🇭🇰香港 02", "🇭🇰香港 02"),
            plan.operations.map { it.proxyGroup },
        )
    }

    @Test
    fun `multiple clauses route each service to its requested region`() {
        val proxies = snapshot().proxies.toMutableMap()
        proxies["🇯🇵日本 02"] = MihomoRepository.ProxyState(
            "🇯🇵日本 02", "Vless", null, emptyList(), 55, true,
        )
        proxies["🇺🇸美国 01"] = MihomoRepository.ProxyState(
            "🇺🇸美国 01", "Vless", null, emptyList(), 70, true,
        )

        val plan = LocalPlanResolver.resolve(
            "Netflix 走日本，YouTube 走美国",
            MihomoRepository.RoutingSnapshot(proxies),
        )!!

        assertEquals(listOf("netflix", "youtube"), plan.operations.map { it.target })
        assertEquals(
            listOf("🇯🇵日本 02", "🇺🇸美国 01"),
            plan.operations.map { it.proxyGroup },
        )
    }

    @Test
    fun `unhealthy region is not guessed locally`() {
        assertNull(LocalPlanResolver.resolve("Netflix走日本", snapshot()))
    }

    @Test
    fun `detects unavailable UK request before LLM can silently substitute region`() {
        assertEquals(
            setOf("GB"),
            LocalPlanResolver.requestedRoutingRegionCodes("我想看DisneyPlus英区"),
        )
    }

    @Test
    fun `regional diagnosis is not treated as a routing mutation`() {
        assertEquals(
            emptySet<String>(),
            LocalPlanResolver.requestedRoutingRegionCodes("为什么日本节点打不开"),
        )
    }

    @Test
    fun `known service direct command uses geosite locally`() {
        val operation = LocalPlanResolver.resolve(
            "Netflix 不走代理",
            snapshot(),
        )!!.operations.single()

        assertEquals("netflix", operation.target)
        assertEquals(AiIntent.MatchType.GEOSITE, operation.matchType)
        assertEquals("DIRECT", operation.proxyGroup)
    }

    @Test
    fun `node with unknown health remains eligible when it is not known bad`() {
        val proxies = snapshot().proxies.toMutableMap()
        proxies["🇹🇼台湾 01"] = MihomoRepository.ProxyState(
            "🇹🇼台湾 01", "Vless", null, emptyList(), null, null,
        )

        val operation = LocalPlanResolver.resolve(
            "Netflix走台湾",
            MihomoRepository.RoutingSnapshot(proxies),
        )!!.operations.single()

        assertEquals("🇹🇼台湾 01", operation.proxyGroup)
    }

    @Test
    fun `Disney Plus is canonicalized to supported disney geosite`() {
        val proxies = snapshot().proxies.toMutableMap()
        proxies["🇬🇧英国 01"] = MihomoRepository.ProxyState(
            "🇬🇧英国 01", "Vless", null, emptyList(), 75, true,
        )

        val operation = LocalPlanResolver.resolve(
            "DisneyPlus走英国节点",
            MihomoRepository.RoutingSnapshot(proxies),
        )!!.operations.single()

        assertEquals("disney", operation.target)
        assertEquals(AiIntent.MatchType.GEOSITE, operation.matchType)
        assertEquals("🇬🇧英国 01", operation.proxyGroup)
    }

    private fun snapshot(): MihomoRepository.RoutingSnapshot {
        val proxies = listOf(
            MihomoRepository.ProxyState(
                "GLOBAL", "Selector", "DIRECT", listOf("DIRECT"), null,
            ),
            MihomoRepository.ProxyState(
                "千速云", "Selector", "自动选择",
                listOf("自动选择", "🇭🇰香港 01", "🇭🇰香港 02", "🇯🇵日本 01"), null,
            ),
            MihomoRepository.ProxyState(
                "自动选择", "URLTest", "🇭🇰香港 02",
                listOf("🇭🇰香港 01", "🇭🇰香港 02"), 30, true,
            ),
            MihomoRepository.ProxyState("🇭🇰香港 01", "Vless", null, emptyList(), 80, true),
            MihomoRepository.ProxyState("🇭🇰香港 02", "Vless", null, emptyList(), 40, true),
            MihomoRepository.ProxyState("🇯🇵日本 01", "Vless", null, emptyList(), 90, false),
            MihomoRepository.ProxyState("DIRECT", "Direct", null, emptyList(), null, true),
        ).associateBy { it.name }
        return MihomoRepository.RoutingSnapshot(proxies)
    }
}
