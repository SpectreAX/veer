package com.yamax.veer.core_mihomo

/**
 * Emitted by [ConnectivityMonitor]'s NetworkCallback overrides and delivered to
 * [ConnectivityMonitor.Companion.eventObserver] (null in production).
 *
 * All subclasses are data classes so tests can assert equality directly.
 */
internal sealed class ConnectivityEvent {
    abstract val networkHandle: Long
    abstract val timestampMs: Long
    abstract val threadName: String

    data class Available(
        override val networkHandle: Long,
        /** Human-readable transport labels, e.g. "WIFI" or "CELL+WIFI". */
        val transports: String,
        val validated: Boolean,
        override val timestampMs: Long,
        override val threadName: String,
    ) : ConnectivityEvent()

    data class Lost(
        override val networkHandle: Long,
        /** Active network count after this network was removed. */
        val remainingCount: Int,
        override val timestampMs: Long,
        override val threadName: String,
    ) : ConnectivityEvent()

    /**
     * Fired by [ConnectivityMonitor.networkCallback.onCapabilitiesChanged].
     * Covers validated state transitions, transport changes, and captive-portal detection.
     */
    data class CapabilitiesChanged(
        override val networkHandle: Long,
        val transports: String,
        val validated: Boolean,
        val captivePortal: Boolean,
        override val timestampMs: Long,
        override val threadName: String,
    ) : ConnectivityEvent()

    /**
     * Fired by [ConnectivityMonitor.networkCallback.onBlockedStatusChanged] (API 29+).
     * Indicates whether the OS has blocked traffic on this network (e.g. background data
     * restrictions, captive portal interception, or metered network policy).
     */
    data class BlockedStatusChanged(
        override val networkHandle: Long,
        val blocked: Boolean,
        override val timestampMs: Long,
        override val threadName: String,
    ) : ConnectivityEvent()
}
