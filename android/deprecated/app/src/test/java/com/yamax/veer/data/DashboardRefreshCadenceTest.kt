package com.yamax.veer.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DashboardRefreshCadenceTest {
    @Test
    fun `network probes run much less often than binder counters`() {
        assertEquals(1_000L, DashboardRefreshCadence.LIGHTWEIGHT_MS)
        assertTrue(
            DashboardRefreshCadence.NETWORK_MS >=
                DashboardRefreshCadence.LIGHTWEIGHT_MS * 30,
        )
    }
}
