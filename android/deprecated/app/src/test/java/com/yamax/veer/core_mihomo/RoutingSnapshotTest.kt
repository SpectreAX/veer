package com.yamax.veer.core_mihomo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingSnapshotTest {

    @Test
    fun `lowest latency skips current nested node and subscription status entries`() {
        val snapshot = snapshot(
            state("千速云", "Selector", now = "自动选择", members = listOf(
                "自动选择", "套餐到期：长期有效", "🇯🇵日本 01", "🇸🇬新加坡 01",
            )),
            state("自动选择", "URLTest", now = "🇯🇵日本 01", members = listOf(
                "🇯🇵日本 01", "🇸🇬新加坡 01",
            )),
            state("套餐到期：长期有效", "Trojan", delay = 5),
            state("🇯🇵日本 01", "Vless", delay = 42),
            state("🇸🇬新加坡 01", "Vless", delay = 58),
        )

        val selected = snapshot.lowestLatencyCandidate("千速云")

        assertEquals("🇸🇬新加坡 01", selected?.name)
        assertEquals(58, selected?.delayMs)
    }

    @Test
    fun `lowest latency returns null when selector has no measured alternative`() {
        val snapshot = snapshot(
            state("PROXY", "Selector", now = "HK", members = listOf("HK", "JP")),
            state("HK", "Vless", delay = 20),
            state("JP", "Vless"),
        )

        assertNull(snapshot.lowestLatencyCandidate("PROXY"))
    }

    @Test
    fun `automatic latency candidate prefers url test group when leaf probes are unavailable`() {
        val snapshot = snapshot(
            state("千速云", "Selector", now = "HK", members = listOf("自动选择", "故障转移", "HK")),
            state("自动选择", "URLTest", now = "SG", members = listOf("HK", "SG")),
            state("故障转移", "Fallback", now = "JP", members = listOf("JP", "US")),
            state("HK", "Vless"),
            state("SG", "Vless"),
            state("JP", "Vless"),
            state("US", "Vless"),
        )

        assertEquals("自动选择", snapshot.automaticLatencyCandidate("千速云")?.name)
    }

    @Test
    fun `automatic group pointing at subscription metadata is skipped`() {
        val snapshot = snapshot(
            state("千速云", "Selector", now = "HK", members = listOf("自动选择", "故障转移", "HK")),
            state(
                "自动选择",
                "URLTest",
                now = "套餐到期：长期有效",
                members = listOf("套餐到期：长期有效", "HK"),
            ),
            state("故障转移", "Fallback", now = "HK", members = listOf("HK")),
            state("套餐到期：长期有效", "Trojan"),
            state("HK", "Vless"),
        )

        assertEquals("故障转移", snapshot.automaticLatencyCandidate("千速云")?.name)
    }

    @Test
    fun `detects when selector is already using automatic group`() {
        val snapshot = snapshot(
            state("千速云", "Selector", now = "自动选择", members = listOf("自动选择", "HK")),
            state("自动选择", "URLTest", now = "HK", members = listOf("HK")),
            state("HK", "Vless", delay = 20),
        )

        assertTrue(snapshot.isUsingAutomaticSelector("千速云"))
        assertFalse(snapshot.isUsingAutomaticSelector("missing"))
    }

    @Test
    fun `failed probes keep current automatic group instead of oscillating`() {
        val snapshot = snapshot(
            state("千速云", "Selector", now = "自动选择", members = listOf(
                "自动选择", "故障转移", "HK",
            )),
            state("自动选择", "URLTest", now = "HK", members = listOf("HK", "JP")),
            state("故障转移", "Fallback", now = "JP", members = listOf("HK", "JP")),
            state("HK", "Vless"),
            state("JP", "Vless"),
        )

        assertEquals("自动选择", snapshot.latencyFallbackCandidate("千速云")?.name)
    }

    @Test
    fun `dead nodes are excluded from historical latency selection`() {
        val snapshot = snapshot(
            state("PROXY", "Selector", now = "HK", members = listOf("HK", "JP", "US")),
            state("HK", "Vless", delay = 20),
            state("JP", "Vless", delay = 5, alive = false),
            state("US", "Vless", delay = 60, alive = true),
        )

        assertEquals("US", snapshot.lowestLatencyCandidate("PROXY")?.name)
    }

    @Test
    fun `available equivalent recognizes common region naming styles`() {
        val snapshot = snapshot(
            state("JP-Tokyo-01", "Vless", delay = 20, alive = false),
            state("🇯🇵日本 02", "Vless", delay = 50, alive = true),
            state("US-Los-Angeles", "Vless", delay = 30, alive = true),
        )

        assertEquals("🇯🇵日本 02", snapshot.availableEquivalent("JP-Tokyo-01")?.name)
    }

    @Test
    fun `unavailable regional node is rejected when no equivalent is alive`() {
        val snapshot = snapshot(
            state("🇯🇵日本 01", "Vless", delay = 65535, alive = false),
            state("JP-Tokyo-02", "Vless", delay = 65535, alive = false),
            state("🇺🇸美国 01", "Vless", delay = 30, alive = true),
        )

        assertTrue(snapshot.isKnownUnavailable("🇯🇵日本 01"))
        assertNull(snapshot.availableEquivalent("🇯🇵日本 01"))
    }

    @Test
    fun `automatic groups remain valid rule policies even when leaf health changes`() {
        val snapshot = snapshot(
            state("自动选择", "URLTest", now = "JP", members = listOf("JP", "US")),
            state("JP", "Vless", delay = 65535, alive = false),
            state("US", "Vless", delay = 50, alive = true),
        )

        assertFalse(snapshot.isKnownUnavailable("自动选择"))
        assertEquals("自动选择", snapshot.availableEquivalent("自动选择")?.name)
    }

    @Test
    fun `proxy states expose region codes for common node naming styles`() {
        assertEquals("JP", state("🇯🇵日本 01", "Vless").regionCode)
        assertEquals("US", state("US-Los-Angeles", "Vless").regionCode)
        assertEquals("HK", state("Hong Kong Premium", "Trojan").regionCode)
        assertNull(state("未分类节点", "Trojan").regionCode)
    }

    @Test
    fun `resolved leaf follows nested selector chain`() {
        val snapshot = snapshot(
            state("GLOBAL", "Selector", now = "千速云", members = listOf("千速云", "DIRECT")),
            state("千速云", "Selector", now = "自动选择", members = listOf("自动选择", "JP")),
            state("自动选择", "URLTest", now = "JP", members = listOf("JP", "US")),
            state("JP", "Vless", delay = 42, alive = true),
            state("US", "Vless", delay = 80, alive = true),
        )

        assertEquals("JP", snapshot.resolvedLeaf("GLOBAL")?.name)
        assertNull(snapshot.resolvedLeaf("missing"))
    }

    private fun snapshot(vararg states: MihomoRepository.ProxyState) =
        MihomoRepository.RoutingSnapshot(states.associateBy { it.name })

    private fun state(
        name: String,
        type: String,
        now: String? = null,
        members: List<String> = emptyList(),
        delay: Int? = null,
        alive: Boolean? = null,
    ) = MihomoRepository.ProxyState(name, type, now, members, delay, alive)
}
