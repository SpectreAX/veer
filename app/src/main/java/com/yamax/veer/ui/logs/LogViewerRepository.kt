package com.yamax.veer.ui.logs

import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.ipc.CoreStateClient
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal class LogViewerRepository {
    fun snapshot(): List<ViewerLogLine> {
        val local = VeerLog.ringSnapshot().mapIndexed { index, entry ->
            ViewerLogLine(
                id = "ui-$index-${entry.timestampMs}",
                time = requireNotNull(TIME_FORMAT.get()).format(Date(entry.timestampMs)),
                source = LogSource.UI,
                level = entry.level.toViewerLevel(),
                category = entry.cat.key,
                message = entry.message,
            )
        }
        val core = CoreStateClient.logSnapshot(limit = CORE_LIMIT)
            .mapIndexed { index, line ->
                LogViewerParser.parseCore(line, index)
            }

        return (local + core)
            .sortedWith(
                compareByDescending<ViewerLogLine> { it.time }
                    .thenBy { it.source.name },
            )
            .take(TOTAL_LIMIT)
    }

    private fun VeerLog.Level.toViewerLevel(): ViewerLogLevel = when (this) {
        VeerLog.Level.DEBUG -> ViewerLogLevel.DEBUG
        VeerLog.Level.INFO -> ViewerLogLevel.INFO
        VeerLog.Level.WARN -> ViewerLogLevel.WARN
        VeerLog.Level.ERROR -> ViewerLogLevel.ERROR
    }

    private companion object {
        const val CORE_LIMIT = 200
        const val TOTAL_LIMIT = 700
        val TIME_FORMAT = ThreadLocal.withInitial {
            SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
        }
    }
}
