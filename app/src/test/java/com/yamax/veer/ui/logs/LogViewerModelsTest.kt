package com.yamax.veer.ui.logs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LogViewerModelsTest {

    @Test
    fun parsesStructuredCoreLineWithLevelAndCategory() {
        val parsed = LogViewerParser.parseCore(
            "12:34:56.789  W  [watchdog]  controller probe failed",
            ordinal = 4,
        )

        assertEquals("12:34:56.789", parsed.time)
        assertEquals(LogSource.CORE, parsed.source)
        assertEquals(ViewerLogLevel.WARN, parsed.level)
        assertEquals("watchdog", parsed.category)
        assertEquals("controller probe failed", parsed.message)
    }

    @Test
    fun keepsLegacyAndMalformedCoreLinesVisible() {
        val legacy = LogViewerParser.parseCore(
            "01:02:03.004  [go]  old format",
            ordinal = 1,
        )
        val malformed = LogViewerParser.parseCore("unstructured native line", ordinal = 2)

        assertEquals(ViewerLogLevel.UNKNOWN, legacy.level)
        assertEquals("go", legacy.category)
        assertEquals("old format", legacy.message)
        assertEquals(ViewerLogLevel.UNKNOWN, malformed.level)
        assertEquals("unknown", malformed.category)
        assertEquals("unstructured native line", malformed.message)
    }

    @Test
    fun combinesSourceLevelAndQueryFilters() {
        val lines = listOf(
            line("1", LogSource.UI, ViewerLogLevel.INFO, "ui", "VPN start requested"),
            line("2", LogSource.CORE, ViewerLogLevel.WARN, "watchdog", "VPN probe failed"),
            line("3", LogSource.CORE, ViewerLogLevel.ERROR, "go", "native panic"),
        )

        val visible = LogViewerFiltering.apply(
            lines,
            LogViewerFilter(
                query = "vpn",
                source = LogSourceFilter.CORE,
                level = ViewerLogLevel.WARN,
            ),
        )

        assertEquals(listOf("2"), visible.map(ViewerLogLine::id))
    }

    @Test
    fun emptyFilterPreservesEveryLine() {
        val lines = listOf(
            line("1", LogSource.UI, ViewerLogLevel.DEBUG, "ui", "first"),
            line("2", LogSource.CORE, ViewerLogLevel.UNKNOWN, "legacy", "second"),
        )

        assertEquals(lines, LogViewerFiltering.apply(lines, LogViewerFilter()))
        assertTrue(lines.first().formatted().contains("[ui/ui]"))
    }

    private fun line(
        id: String,
        source: LogSource,
        level: ViewerLogLevel,
        category: String,
        message: String,
    ) = ViewerLogLine(
        id = id,
        time = "12:00:00.000",
        source = source,
        level = level,
        category = category,
        message = message,
    )
}
