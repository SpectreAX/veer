package com.yamax.veer.testing

import kotlinx.coroutines.delay
import veercore.Veercore

/**
 * Kotlin wrapper around the Go-side goroutine snapshot API.
 *
 * Requires veercore.Veercore.takeGoroutineSnapshot to return a non-zero
 * count, which only happens when the debug .aar is loaded (built with the
 * `veer_fault_inject` Go build tag). Call [isAvailable] before using
 * count-based assertions; tests should skip gracefully when unavailable.
 *
 * Only compiled in the debug source set.
 */
internal object GoroutineInventory {

    data class Snapshot(
        val count: Int,
        val timestampMs: Long,
        val stacks: String,
    )

    /**
     * Returns true when the debug .aar is loaded and goroutine snapshots are
     * meaningful. The production noop stub always returns count == 0; even an
     * idle Go runtime has at least 2–3 internal goroutines.
     */
    val isAvailable: Boolean by lazy { takeSnapshot(false).count > 0 }

    fun take(includeStacks: Boolean = false): Snapshot = takeSnapshot(includeStacks)

    fun delta(before: Snapshot, after: Snapshot): Int = after.count - before.count

    /**
     * Polls until the goroutine delta between [baseline] and the current
     * snapshot satisfies [predicate], or [timeoutMs] elapses.
     * Returns the final snapshot regardless of whether the predicate was met.
     */
    suspend fun awaitDelta(
        baseline: Snapshot,
        timeoutMs: Long = 2_000L,
        pollMs: Long = 100L,
        predicate: (Int) -> Boolean,
    ): Snapshot {
        val deadline = System.currentTimeMillis() + timeoutMs
        var last = take()
        while (System.currentTimeMillis() < deadline) {
            if (predicate(delta(baseline, last))) return last
            delay(pollMs)
            last = take()
        }
        return last
    }

    // Calls veercore.Veercore.takeGoroutineSnapshot(boolean) via reflection so
    // this file compiles against any .aar variant. Returns a zero snapshot when
    // the method is absent (production .aar) or throws.
    private fun takeSnapshot(includeStacks: Boolean): Snapshot = runCatching {
        val m = Veercore::class.java.methods
            .firstOrNull { it.name == "takeGoroutineSnapshot" && it.parameterCount == 1 }
            ?: return@runCatching Snapshot(0, 0L, "")
        val result = m.invoke(null, includeStacks)
            ?: return@runCatching Snapshot(0, 0L, "")
        val rc     = result.javaClass
        val count  = (rc.getMethod("getCount").invoke(result) as? Long ?: 0L).toInt()
        val ts     = rc.getMethod("getTimestamp").invoke(result) as? Long ?: 0L
        val stacks = rc.getMethod("getStacks").invoke(result) as? String ?: ""
        Snapshot(count, ts, stacks)
    }.getOrDefault(Snapshot(0, 0L, ""))
}
