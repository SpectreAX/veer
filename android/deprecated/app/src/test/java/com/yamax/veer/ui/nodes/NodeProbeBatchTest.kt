package com.yamax.veer.ui.nodes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NodeProbeBatchTest {

    @Test
    fun targetsAreDeduplicatedAcrossGroupsInStableOrder() {
        val groups = listOf(
            group("手动选择", node("香港 01"), node("日本 01")),
            group("自动选择", node("日本 01"), node("美国 01")),
        )

        assertEquals(
            listOf("香港 01", "日本 01", "美国 01"),
            uniqueProbeTargets(groups),
        )
    }

    @Test
    fun resultUpdatesEveryReferenceToTheSameNode() {
        val groups = listOf(
            group("手动选择", node("日本 01")),
            group("自动选择", node("日本 01")),
        )

        val updated = applyProbeResult(groups, "日本 01", 42)

        updated.forEach { group ->
            assertEquals(42, group.nodes.single().delayMs)
            assertTrue(group.nodes.single().alive == true)
        }
    }

    @Test
    fun failedResultClearsDelayAndMarksNodeUnavailable() {
        val groups = listOf(group("手动选择", node("香港 01", delayMs = 10)))

        val updated = applyProbeResult(groups, "香港 01", null)
        val result = updated.single().nodes.single()

        assertNull(result.delayMs)
        assertFalse(result.alive == true)
    }

    @Test
    fun progressCountsSuccessfulAndFailedMeasurements() {
        val progress = BatchProbeProgress(total = 3)
            .record(success = true)
            .record(success = false)
            .record(success = true)

        assertEquals(3, progress.completed)
        assertEquals(2, progress.successful)
        assertEquals(1, progress.failed)
        assertEquals(1f, progress.fraction)
    }

    private fun group(name: String, vararg nodes: NodeUi) = ProxyGroupUi(
        name = name,
        type = "Selector",
        selected = nodes.firstOrNull()?.name,
        nodes = nodes.toList(),
        selectable = true,
    )

    private fun node(name: String, delayMs: Int? = null) = NodeUi(
        name = name,
        type = "Vless",
        region = null,
        delayMs = delayMs,
        alive = delayMs?.let { true },
        selected = false,
    )
}
