package com.yamax.veer.core_mihomo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchdogFailureTrackerTest {

    @Test
    fun `triggers only after three consecutive failures`() {
        val tracker = WatchdogFailureTracker(failureThreshold = 3)

        assertFalse(tracker.record(reachable = false))
        assertFalse(tracker.record(reachable = false))
        assertTrue(tracker.record(reachable = false))
        assertEquals(3, tracker.consecutiveFailures)
    }

    @Test
    fun `successful probe resets failure streak`() {
        val tracker = WatchdogFailureTracker(failureThreshold = 3)

        assertFalse(tracker.record(reachable = false))
        assertFalse(tracker.record(reachable = false))
        assertFalse(tracker.record(reachable = true))
        assertEquals(0, tracker.consecutiveFailures)
        assertFalse(tracker.record(reachable = false))
        assertEquals(1, tracker.consecutiveFailures)
    }

    @Test
    fun `rejects non-positive threshold`() {
        assertThrows(IllegalArgumentException::class.java) {
            WatchdogFailureTracker(failureThreshold = 0)
        }
    }
}
