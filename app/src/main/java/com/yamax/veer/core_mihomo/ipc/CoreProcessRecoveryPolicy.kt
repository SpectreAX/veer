package com.yamax.veer.core_mihomo.ipc

internal object CoreProcessRecoveryPolicy {
    /**
     * Recover only when a process that was observed Running has been replaced
     * by a new, currently stopped core process while the user still expects the
     * VPN to be connected. This excludes ordinary startup, explicit stop and
     * recoverable runtime errors.
     */
    fun shouldRecover(
        previousProcessId: Int,
        currentProcessId: Int,
        lastRunningProcessId: Int,
        currentCoreStopped: Boolean,
        desiredRunning: Boolean,
    ): Boolean =
        previousProcessId > 0 &&
            currentProcessId > 0 &&
            previousProcessId != currentProcessId &&
            lastRunningProcessId == previousProcessId &&
            currentCoreStopped &&
            desiredRunning
}
