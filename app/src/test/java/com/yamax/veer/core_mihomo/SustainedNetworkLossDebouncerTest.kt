package com.yamax.veer.core_mihomo

import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.assertEquals
import org.junit.Test

class SustainedNetworkLossDebouncerTest {
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `transient handoff gap is cancelled but sustained outage emits once`() = runTest {
        var lost = true
        var emissions = 0
        val debouncer = SustainedNetworkLossDebouncer(
            scope = this,
            debounceMs = 2_000L,
            isStillLost = { lost },
            onSustainedLoss = { emissions++ },
        )

        debouncer.onAllNetworksAbsent()
        advanceTimeBy(1_999L)
        runCurrent()
        assertEquals(0, emissions)

        lost = false
        debouncer.onNetworkAvailable()
        advanceTimeBy(2_000L)
        runCurrent()
        assertEquals(0, emissions)

        lost = true
        debouncer.onAllNetworksAbsent()
        advanceTimeBy(2_000L)
        runCurrent()
        assertEquals(1, emissions)
    }
}
