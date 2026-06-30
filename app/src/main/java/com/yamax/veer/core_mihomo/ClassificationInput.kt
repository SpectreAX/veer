package com.yamax.veer.core_mihomo

/**
 * Structured inputs derived from a raw [ConnectivityEvent] window, ready for
 * [ConnectivityTransitionClassifier.classify].
 *
 * Build via [ClassificationInput.from] rather than constructing directly —
 * it computes all derived fields in a single pass over the event list.
 */
internal data class ClassificationInput(
    val events: List<ConnectivityEvent>,
    /** Time gap in ms between events[i] and events[i+1]. Size == events.size − 1. */
    val timingDeltas: List<Long>,
    /** Total ms where 2+ physical networks were simultaneously active, or null if no overlap. */
    val overlapDurationMs: Long?,
    /** Number of validated↔unvalidated state flips across all network handles in the window. */
    val validatedTransitions: Int,
    /** (from, to) transport string pairs where the active transport changed. */
    val transportChanges: List<Pair<String, String>>,
) {
    companion object {
        fun from(events: List<ConnectivityEvent>): ClassificationInput {
            if (events.isEmpty()) return ClassificationInput(emptyList(), emptyList(), null, 0, emptyList())
            return ClassificationInput(
                events            = events,
                timingDeltas      = events.zipWithNext { a, b -> b.timestampMs - a.timestampMs },
                overlapDurationMs = computeOverlapMs(events),
                validatedTransitions = computeValidatedTransitions(events),
                transportChanges  = computeTransportChanges(events),
            )
        }

        private fun computeOverlapMs(events: List<ConnectivityEvent>): Long? {
            val active = mutableSetOf<Long>()
            var overlapStart: Long? = null
            var total = 0L
            for (e in events) {
                when (e) {
                    is ConnectivityEvent.Available -> {
                        active.add(e.networkHandle)
                        if (active.size >= 2 && overlapStart == null) overlapStart = e.timestampMs
                    }
                    is ConnectivityEvent.Lost -> {
                        active.remove(e.networkHandle)
                        // Close the overlap window when active count drops below 2
                        if (active.size < 2 && overlapStart != null) {
                            total += e.timestampMs - overlapStart!!
                            overlapStart = null
                        }
                    }
                    else -> {}
                }
            }
            // Overlap still open at end of window — measure to the last event timestamp
            if (overlapStart != null && active.size >= 2) {
                total += events.last().timestampMs - overlapStart!!
            }
            return if (total > 0L) total else null
        }

        private fun computeValidatedTransitions(events: List<ConnectivityEvent>): Int {
            val state = mutableMapOf<Long, Boolean>()
            var count = 0
            for (e in events) {
                when (e) {
                    is ConnectivityEvent.Available -> state[e.networkHandle] = e.validated
                    is ConnectivityEvent.CapabilitiesChanged -> {
                        val prev = state[e.networkHandle]
                        if (prev != null && prev != e.validated) count++
                        state[e.networkHandle] = e.validated
                    }
                    else -> {}
                }
            }
            return count
        }

        private fun computeTransportChanges(events: List<ConnectivityEvent>): List<Pair<String, String>> {
            val networkTransport = mutableMapOf<Long, String>()
            // Tracks last-seen transport so a post-loss recovery can be compared to pre-loss transport
            var lastSeenTransport: String? = null
            val changes = mutableListOf<Pair<String, String>>()
            for (e in events) {
                when (e) {
                    is ConnectivityEvent.Available -> {
                        val from = lastSeenTransport
                        networkTransport[e.networkHandle] = e.transports
                        lastSeenTransport = e.transports
                        if (from != null && from != e.transports) changes.add(from to e.transports)
                    }
                    is ConnectivityEvent.CapabilitiesChanged -> {
                        val prev = networkTransport[e.networkHandle]
                        if (prev != null && prev != e.transports) {
                            changes.add(prev to e.transports)
                            networkTransport[e.networkHandle] = e.transports
                            lastSeenTransport = e.transports
                        }
                    }
                    is ConnectivityEvent.Lost -> {
                        networkTransport.remove(e.networkHandle)
                        // lastSeenTransport intentionally not cleared so post-recovery
                        // Available can be compared against pre-loss transport
                    }
                    else -> {}
                }
            }
            return changes
        }
    }
}
