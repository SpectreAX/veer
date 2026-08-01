package com.yamax.veer.ui.chart

import org.junit.Assert.assertEquals
import org.junit.Test

class SpeedChartFormattingTest {

    @Test
    fun `format speed uses stable binary units`() {
        assertEquals("0 B/s", formatSpeed(-1))
        assertEquals("1.0 KB/s", formatSpeed(1_024))
        assertEquals("1.0 MB/s", formatSpeed(1_024L * 1_024L))
        assertEquals("1.0 GB/s", formatSpeed(1_024L * 1_024L * 1_024L))
    }
}
