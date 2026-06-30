package com.yamax.veer.testing

import com.yamax.veer.core_mihomo.EngineState
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Ring-buffered log of every [EngineState] transition. Installed into
 * [com.yamax.veer.core_mihomo.MihomoEngine.stateObserver] by [DebugLifecycleSetup].
 *
 * Only compiled in the debug source set. The production MihomoEngine.stateObserver
 * is null, so this class is never referenced outside debug/test builds.
 */
object PhaseTrace {

    data class Event(
        /** Simple class name of the EngineState subtype (e.g. "Running", "Error"). */
        val stateName: String,
        val timestampMs: Long,
        val threadName: String,
        /** First stack frame outside PhaseTrace itself, for call-site attribution. */
        val callerTag: String,
    ) {
        override fun toString(): String = "$timestampMs  $stateName  [$threadName]  $callerTag"
    }

    private const val CAPACITY = 64
    private val lock = ReentrantLock()
    private val buffer = ArrayDeque<Event>(CAPACITY)

    fun record(state: EngineState) {
        val ts     = System.currentTimeMillis()
        val thread = Thread.currentThread().name
        val caller = Thread.currentThread().stackTrace
            .firstOrNull { frame ->
                frame.className != PhaseTrace::class.java.name &&
                frame.className != "com.yamax.veer.core_mihomo.MihomoEngine" &&
                !frame.className.startsWith("java.lang.Thread")
            }
            ?.let { "${it.className.substringAfterLast('.')}:${it.lineNumber}" }
            ?: "?"
        lock.withLock {
            if (buffer.size >= CAPACITY) buffer.removeFirst()
            buffer.addLast(Event(state::class.simpleName ?: state.toString(), ts, thread, caller))
        }
    }

    /** Returns all recorded events without clearing the buffer. */
    fun peek(): List<Event> = lock.withLock { buffer.toList() }

    /** Returns all recorded events and clears the buffer. */
    fun drain(): List<Event> = lock.withLock { buffer.toList().also { buffer.clear() } }

    fun clear() = lock.withLock { buffer.clear() }

    /**
     * Returns the names of all states in order (e.g. ["Starting", "Running"]).
     * Useful for asserting exact transition sequences in tests.
     */
    fun stateNames(): List<String> = peek().map { it.stateName }

    /**
     * Returns true if [expected] appears as a contiguous sub-sequence anywhere
     * in the recorded trace. Use to assert that a specific lifecycle path fired.
     */
    fun containsSequence(vararg expected: String): Boolean {
        val names = stateNames()
        if (expected.isEmpty()) return true
        outer@ for (i in 0..names.size - expected.size) {
            for (j in expected.indices) {
                if (names[i + j] != expected[j]) continue@outer
            }
            return true
        }
        return false
    }

    /** Returns how many times [stateName] appears in the recorded trace. */
    fun countOf(stateName: String): Int = stateNames().count { it == stateName }
}
