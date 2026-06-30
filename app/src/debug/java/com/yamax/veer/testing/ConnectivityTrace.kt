package com.yamax.veer.testing

import com.yamax.veer.core_mihomo.ConnectivityEvent
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Ring-buffered log of [ConnectivityEvent]s emitted by ConnectivityMonitor.
 * Installed into ConnectivityMonitor.Companion.eventObserver by [DebugLifecycleSetup].
 *
 * Only compiled in the debug source set. Use [dump] to produce a human-readable
 * multi-line report including debounce diagnostics, transient loss windows, and
 * concurrent network overlap intervals.
 *
 * Capacity is 128 — larger than [PhaseTrace] because network callbacks fire more
 * frequently than state transitions during handover scenarios.
 */
internal object ConnectivityTrace {

    private const val CAPACITY = 128
    private val lock = ReentrantLock()
    private val buffer = ArrayDeque<ConnectivityEvent>(CAPACITY)

    fun record(event: ConnectivityEvent) {
        lock.withLock {
            if (buffer.size >= CAPACITY) buffer.removeFirst()
            buffer.addLast(event)
        }
    }

    fun peek(): List<ConnectivityEvent> = lock.withLock { buffer.toList() }

    fun clear() = lock.withLock { buffer.clear() }

    // -------------------------------------------------------------------------
    // Debug dump
    // -------------------------------------------------------------------------

    /**
     * Returns a multiline diagnostic string. Includes:
     *   • Raw event log with per-event timestamp deltas and thread names
     *   • Transient loss intervals (all-networks-gone → first-available-back)
     *   • Concurrent network overlap windows (handover detection)
     *   • Max concurrent network count observed
     */
    fun dump(): String {
        val events = peek()
        if (events.isEmpty()) return "(no connectivity events recorded)"
        val sb = StringBuilder()
        sb.appendLine("=== ConnectivityTrace (${events.size} events) ===")

        var prevTs = events.first().timestampMs
        events.forEach { e ->
            val delta = e.timestampMs - prevTs
            prevTs = e.timestampMs
            sb.appendLine(formatEvent(e, delta))
        }

        sb.appendLine()
        sb.appendLine("--- Debounce diagnostics ---")
        appendTransientLossDiagnostics(sb, events)
        sb.appendLine()
        appendOverlapDiagnostics(sb, events)

        return sb.trimEnd().toString()
    }

    // -------------------------------------------------------------------------
    // Private formatting helpers
    // -------------------------------------------------------------------------

    private fun formatEvent(e: ConnectivityEvent, deltaMs: Long): String {
        val handle = "net#${e.networkHandle}"
        val thread = "[${e.threadName}]"
        val delta  = if (deltaMs == 0L) "+0ms" else "+${deltaMs}ms"
        return when (e) {
            is ConnectivityEvent.Available -> {
                val v = if (e.validated) "VAL" else "unv"
                "  ${e.timestampMs}  $delta  AVAILABLE       $handle  ${e.transports}  $v  $thread"
            }
            is ConnectivityEvent.Lost -> {
                "  ${e.timestampMs}  $delta  LOST            $handle  remaining=${e.remainingCount}  $thread"
            }
            is ConnectivityEvent.CapabilitiesChanged -> {
                val v = if (e.validated) "VAL" else "unv"
                val c = if (e.captivePortal) " CAPTIVE" else ""
                "  ${e.timestampMs}  $delta  CAPS_CHANGED    $handle  ${e.transports}  $v$c  $thread"
            }
            is ConnectivityEvent.BlockedStatusChanged -> {
                val s = if (e.blocked) "BLOCKED" else "unblocked"
                "  ${e.timestampMs}  $delta  BLOCKED_CHANGE  $handle  $s  $thread"
            }
        }
    }

    /**
     * Identifies windows where ALL networks were gone (remainingCount == 0) and measures
     * the gap until the next Available event.
     *
     * A "transient loss" is a total-network-loss gap that resolved within the trace window.
     * An open loss (no subsequent Available) is flagged separately.
     */
    private fun appendTransientLossDiagnostics(sb: StringBuilder, events: List<ConnectivityEvent>) {
        data class LossWindow(val handle: Long, val startMs: Long)

        var openLoss: LossWindow? = null
        var resolved = 0

        events.forEach { e ->
            when (e) {
                is ConnectivityEvent.Lost -> if (e.remainingCount == 0) {
                    openLoss = LossWindow(e.networkHandle, e.timestampMs)
                }
                is ConnectivityEvent.Available -> if (openLoss != null) {
                    val w = openLoss
                    sb.appendLine(
                        "  transient-loss:  net#${w.handle} → gap ${e.timestampMs - w.startMs}ms → net#${e.networkHandle}"
                    )
                    openLoss = null
                    resolved++
                }
                else -> {}
            }
        }
        if (openLoss != null) {
            sb.appendLine("  transient-loss:  net#${openLoss.handle} LOST — not recovered within trace window")
        }
        if (resolved == 0 && openLoss == null) {
            sb.appendLine("  transient-loss:  none detected")
        }
    }

    /**
     * Tracks windows where 2+ physical networks were active simultaneously.
     * This is the handover overlap: Android keeps the old network alive until
     * the new one is validated, giving connections time to migrate.
     */
    private fun appendOverlapDiagnostics(sb: StringBuilder, events: List<ConnectivityEvent>) {
        val active = mutableSetOf<Long>()
        var maxConcurrent = 0
        var overlapStart: Long? = null
        var overlapCount = 0

        events.forEach { e ->
            when (e) {
                is ConnectivityEvent.Available -> {
                    active.add(e.networkHandle)
                    if (active.size > maxConcurrent) maxConcurrent = active.size
                    if (active.size >= 2 && overlapStart == null) overlapStart = e.timestampMs
                }
                is ConnectivityEvent.Lost -> {
                    active.remove(e.networkHandle)
                    if (active.size < 2 && overlapStart != null) {
                        val duration = e.timestampMs - overlapStart
                        sb.appendLine("  overlap:         window ${duration}ms ended (${active.size} net(s) remaining)")
                        overlapCount++
                        overlapStart = null
                    }
                }
                else -> {}
            }
        }
        if (overlapStart != null) {
            sb.appendLine("  overlap:         window still open (${active.size} net(s) active)")
        }
        if (overlapCount == 0 && overlapStart == null) {
            sb.appendLine("  overlap:         none detected")
        }
        sb.appendLine("  max-concurrent:  $maxConcurrent network(s)")
    }
}
