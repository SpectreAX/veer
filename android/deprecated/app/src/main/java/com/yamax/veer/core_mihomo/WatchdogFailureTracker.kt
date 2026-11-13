package com.yamax.veer.core_mihomo

/**
 * Counts consecutive failed runtime health probes.
 *
 * A successful probe resets the streak. Returning true means the configured
 * failure threshold has been reached and the caller should stop the runtime.
 */
internal class WatchdogFailureTracker(
    private val failureThreshold: Int,
) {
    init {
        require(failureThreshold > 0) { "failureThreshold must be positive" }
    }

    var consecutiveFailures: Int = 0
        private set

    fun record(reachable: Boolean): Boolean {
        if (reachable) {
            consecutiveFailures = 0
            return false
        }

        consecutiveFailures += 1
        return consecutiveFailures >= failureThreshold
    }
}
