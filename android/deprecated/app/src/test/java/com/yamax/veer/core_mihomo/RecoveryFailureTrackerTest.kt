package com.yamax.veer.core_mihomo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryFailureTrackerTest {
    @Test
    fun `triggers only after configured consecutive failures`() {
        val tracker = RecoveryFailureTracker(threshold = 2)

        assertFalse(tracker.record(healthy = false))
        assertEquals(1, tracker.consecutiveFailures)
        assertTrue(tracker.record(healthy = false))
        assertEquals(2, tracker.consecutiveFailures)
    }

    @Test
    fun `healthy observation resets accumulated failures`() {
        val tracker = RecoveryFailureTracker(threshold = 2)

        tracker.record(healthy = false)
        tracker.record(healthy = true)

        assertEquals(0, tracker.consecutiveFailures)
        assertFalse(tracker.record(healthy = false))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `rejects non-positive threshold`() {
        RecoveryFailureTracker(threshold = 0)
    }
}
