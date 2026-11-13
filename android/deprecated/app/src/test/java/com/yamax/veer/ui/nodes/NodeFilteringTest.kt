package com.yamax.veer.ui.nodes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NodeFilteringTest {

    @Test
    fun `default mode preserves subscription order`() {
        val nodes = listOf(
            node("third", delay = 300),
            node("first", delay = 10),
            node("second", delay = 100),
        )

        val result = filterAndSortGroups(
            groups = listOf(group("PROXY", nodes)),
            filter = NodeFilter(),
        )

        assertEquals(nodes.map(NodeUi::name), result.single().nodes.map(NodeUi::name))
    }

    @Test
    fun `region filter is case insensitive and removes empty groups`() {
        val result = filterAndSortGroups(
            groups = listOf(
                group("mixed", listOf(node("Japan", region = "JP"), node("US", region = "US"))),
                group("hong-kong", listOf(node("HK", region = "HK"))),
            ),
            filter = NodeFilter(regionFilter = "jp"),
        )

        assertEquals(listOf("mixed"), result.map(ProxyGroupUi::name))
        assertEquals(listOf("Japan"), result.single().nodes.map(NodeUi::name))
    }

    @Test
    fun `hide unavailable keeps untested nodes but removes dead and timeout nodes`() {
        val result = filterAndSortGroups(
            groups = listOf(
                group(
                    "PROXY",
                    listOf(
                        node("untested"),
                        node("available", delay = 80, alive = true),
                        node("dead", delay = 10, alive = false),
                        node("timeout", delay = UNAVAILABLE_DELAY_MS, alive = null),
                    ),
                ),
            ),
            filter = NodeFilter(hideUnavailable = true),
        )

        assertEquals(
            listOf("untested", "available"),
            result.single().nodes.map(NodeUi::name),
        )
    }

    @Test
    fun `delay sort puts measured nodes first then untested then unavailable`() {
        val result = filterAndSortGroups(
            groups = listOf(
                group(
                    "PROXY",
                    listOf(
                        node("unknown"),
                        node("slow", delay = 280),
                        node("timeout", delay = UNAVAILABLE_DELAY_MS),
                        node("fast", delay = 40),
                        node("dead", delay = 5, alive = false),
                    ),
                ),
            ),
            filter = NodeFilter(sortMode = NodeSortMode.DELAY_ASC),
        )

        assertEquals(
            listOf("fast", "slow", "unknown", "dead", "timeout"),
            result.single().nodes.map(NodeUi::name),
        )
    }

    @Test
    fun `name sort ignores letter case`() {
        val result = filterAndSortGroups(
            groups = listOf(
                group(
                    "PROXY",
                    listOf(node("charlie"), node("Alpha"), node("bravo")),
                ),
            ),
            filter = NodeFilter(sortMode = NodeSortMode.NAME_ASC),
        )

        assertEquals(
            listOf("Alpha", "bravo", "charlie"),
            result.single().nodes.map(NodeUi::name),
        )
    }

    @Test
    fun `region sort groups known regions and leaves unclassified nodes last`() {
        val result = filterAndSortGroups(
            groups = listOf(
                group(
                    "PROXY",
                    listOf(
                        node("unknown", region = null, delay = 5),
                        node("jp-slow", region = "JP", delay = 80),
                        node("hk", region = "HK", delay = 100),
                        node("jp-fast", region = "JP", delay = 20),
                    ),
                ),
            ),
            filter = NodeFilter(sortMode = NodeSortMode.REGION),
        )

        assertEquals(
            listOf("hk", "jp-fast", "jp-slow", "unknown"),
            result.single().nodes.map(NodeUi::name),
        )
    }

    @Test
    fun `delay presentation covers thresholds and invalid values`() {
        assertEquals(DelayQuality.UNTESTED, delayPresentation(null, null).quality)
        assertEquals(DelayQuality.UNTESTED, delayPresentation(-1, null).quality)
        assertEquals(DelayQuality.FAST, delayPresentation(100, true).quality)
        assertEquals(DelayQuality.MEDIUM, delayPresentation(101, true).quality)
        assertEquals(DelayQuality.MEDIUM, delayPresentation(300, true).quality)
        assertEquals(DelayQuality.SLOW, delayPresentation(301, true).quality)
        assertEquals(DelayQuality.UNAVAILABLE, delayPresentation(65_535, null).quality)
        assertEquals(DelayQuality.UNAVAILABLE, delayPresentation(20, false).quality)
        assertEquals(
            com.yamax.veer.R.string.nodes_delay_timeout,
            (delayPresentation(70_000, true).text as com.yamax.veer.ui.UiText.Resource).resourceId,
        )
    }

    @Test
    fun `empty result contains no placeholder strategy groups`() {
        val result = filterAndSortGroups(
            groups = listOf(group("US only", listOf(node("US", region = "US")))),
            filter = NodeFilter(regionFilter = "JP"),
        )

        assertTrue(result.isEmpty())
    }

    private fun group(name: String, nodes: List<NodeUi>) = ProxyGroupUi(
        name = name,
        type = "Selector",
        selected = nodes.firstOrNull()?.name,
        nodes = nodes,
        selectable = true,
    )

    private fun node(
        name: String,
        region: String? = null,
        delay: Int? = null,
        alive: Boolean? = delay?.let { it < UNAVAILABLE_DELAY_MS },
    ) = NodeUi(
        name = name,
        type = "Vless",
        region = region,
        delayMs = delay,
        alive = alive,
        selected = false,
    )
}
