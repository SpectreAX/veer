package com.yamax.veer.ui.logs

enum class LogSource {
    UI,
    CORE,
}
enum class ViewerLogLevel(val letter: Char?) {
    DEBUG('D'),
    INFO('I'),
    WARN('W'),
    ERROR('E'),
    UNKNOWN(null);

    companion object {
        fun fromLetter(value: String?): ViewerLogLevel = when (value?.uppercase()) {
            "D" -> DEBUG
            "I" -> INFO
            "W" -> WARN
            "E" -> ERROR
            else -> UNKNOWN
        }
    }
}

enum class LogSourceFilter {
    ALL,
    UI,
    CORE,
}

data class ViewerLogLine(
    val id: String,
    val time: String,
    val source: LogSource,
    val level: ViewerLogLevel,
    val category: String,
    val message: String,
) {
    fun formatted(): String = buildString {
        append(time)
        append(' ')
        append(level.letter ?: '?')
        append(" [")
        append(source.name.lowercase())
        append('/')
        append(category)
        append("] ")
        append(message)
    }
}

data class LogViewerFilter(
    val query: String = "",
    val source: LogSourceFilter = LogSourceFilter.ALL,
    val level: ViewerLogLevel? = null,
)

object LogViewerParser {
    private val structured = Regex(
        """^(\d{2}:\d{2}:\d{2}\.\d{3})\s+([DIWE])\s+\[([^]]+)]\s+(.*)$""",
    )
    private val legacy = Regex(
        """^(\d{2}:\d{2}:\d{2}\.\d{3})\s+\[([^]]+)]\s+(.*)$""",
    )

    fun parseCore(line: String, ordinal: Int): ViewerLogLine {
        structured.matchEntire(line)?.let { match ->
            return ViewerLogLine(
                id = "core-$ordinal-${line.hashCode()}",
                time = match.groupValues[1],
                source = LogSource.CORE,
                level = ViewerLogLevel.fromLetter(match.groupValues[2]),
                category = match.groupValues[3],
                message = match.groupValues[4],
            )
        }
        legacy.matchEntire(line)?.let { match ->
            return ViewerLogLine(
                id = "core-$ordinal-${line.hashCode()}",
                time = match.groupValues[1],
                source = LogSource.CORE,
                level = ViewerLogLevel.UNKNOWN,
                category = match.groupValues[2],
                message = match.groupValues[3],
            )
        }
        return ViewerLogLine(
            id = "core-$ordinal-${line.hashCode()}",
            time = "--:--:--.---",
            source = LogSource.CORE,
            level = ViewerLogLevel.UNKNOWN,
            category = "unknown",
            message = line,
        )
    }
}

object LogViewerFiltering {
    fun apply(
        lines: List<ViewerLogLine>,
        filter: LogViewerFilter,
    ): List<ViewerLogLine> {
        val query = filter.query.trim()
        return lines.filter { line ->
            val sourceMatches = when (filter.source) {
                LogSourceFilter.ALL -> true
                LogSourceFilter.UI -> line.source == LogSource.UI
                LogSourceFilter.CORE -> line.source == LogSource.CORE
            }
            val levelMatches = filter.level == null || line.level == filter.level
            val queryMatches = query.isEmpty() ||
                line.category.contains(query, ignoreCase = true) ||
                line.message.contains(query, ignoreCase = true)
            sourceMatches && levelMatches && queryMatches
        }
    }
}
