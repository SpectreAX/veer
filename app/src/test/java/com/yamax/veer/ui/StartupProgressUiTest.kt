package com.yamax.veer.ui

import com.yamax.veer.core_mihomo.StartupStage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupProgressUiTest {

    @Test
    fun `visible startup milestones are monotonic and bounded`() {
        val stages = listOf(
            StartupStage.PREPARING_CONFIG,
            StartupStage.ENSURING_GEO_DATA,
            StartupStage.VALIDATING_CONFIG,
            StartupStage.ESTABLISHING_TUNNEL,
            StartupStage.STARTING_RUNTIME,
            StartupStage.READY,
        )

        val models = stages.map(::startupProgressUi)

        assertTrue(models.zipWithNext().all { (left, right) -> left.progress < right.progress })
        assertTrue(models.all { it.progress in 0f..1f })
        assertEquals(1, models.first().step)
        assertEquals(5, models.last().step)
        assertEquals(1f, models.last().progress)
    }

    @Test
    fun `each active stage has a user facing description`() {
        StartupStage.entries
            .filterNot { it == StartupStage.IDLE }
            .map(::startupProgressUi)
            .forEach { model ->
                assertTrue(model.detailRes != 0)
                assertTrue(model.totalSteps > 0)
            }
    }
}
