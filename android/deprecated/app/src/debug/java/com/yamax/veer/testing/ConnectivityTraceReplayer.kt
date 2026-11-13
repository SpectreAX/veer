package com.yamax.veer.testing

import com.yamax.veer.core_mihomo.ClassificationInput
import com.yamax.veer.core_mihomo.ConnectivityEvent
import com.yamax.veer.core_mihomo.ConnectivityTransitionClassifier
import com.yamax.veer.core_mihomo.TransitionClassification

/**
 * Segmented classification result for one logical transition window inside a [ConnectivityTrace].
 */
internal data class TransitionSummary(
    val windowIndex: Int,
    val windowStartMs: Long,
    val windowEndMs: Long,
    val eventCount: Int,
    val classification: TransitionClassification,
) {
    val windowDurationMs: Long get() = windowEndMs - windowStartMs
}

/**
 * Feeds a [ConnectivityTrace] (or any event list) into [ConnectivityTransitionClassifier]
 * and produces one [TransitionSummary] per logical transition window.
 *
 * Windows are split wherever the gap between consecutive events exceeds [WINDOW_SPLIT_MS].
 * That threshold is long enough to separate distinct network events but short enough to
 * keep a WiFi→Cell handover (typically 200–800 ms) in a single window.
 *
 * Only compiled in the debug source set.
 */
internal object ConnectivityTraceReplayer {

    private const val WINDOW_SPLIT_MS = 10_000L

    fun replay(events: List<ConnectivityEvent> = ConnectivityTrace.peek()): List<TransitionSummary> {
        if (events.isEmpty()) return emptyList()
        return segmentWindows(events).mapIndexed { index, window ->
            val input = ClassificationInput.from(window)
            TransitionSummary(
                windowIndex   = index,
                windowStartMs = window.first().timestampMs,
                windowEndMs   = window.last().timestampMs,
                eventCount    = window.size,
                classification = ConnectivityTransitionClassifier.classify(input),
            )
        }
    }

    /**
     * Returns a multi-line string suitable for logcat or [ConnectivityTrace.dump] appending.
     * Each window section includes the classifier's observability log.
     */
    fun dumpReport(events: List<ConnectivityEvent> = ConnectivityTrace.peek()): String {
        val summaries = replay(events)
        if (summaries.isEmpty()) return "(no events to replay)"
        return buildString {
            appendLine("=== ConnectivityTrace Replay (${summaries.size} window(s)) ===")
            for (s in summaries) {
                appendLine()
                appendLine("--- Window ${s.windowIndex} [${s.windowDurationMs}ms, ${s.eventCount} events] ---")
                append(s.classification.observabilityLog)
                if (s !== summaries.last()) appendLine()
            }
        }.trimEnd()
    }

    private fun segmentWindows(events: List<ConnectivityEvent>): List<List<ConnectivityEvent>> {
        val windows = mutableListOf<MutableList<ConnectivityEvent>>()
        var current = mutableListOf(events.first())
        for (i in 1 until events.size) {
            if (events[i].timestampMs - events[i - 1].timestampMs > WINDOW_SPLIT_MS) {
                windows += current
                current = mutableListOf()
            }
            current += events[i]
        }
        if (current.isNotEmpty()) windows += current
        return windows
    }
}
