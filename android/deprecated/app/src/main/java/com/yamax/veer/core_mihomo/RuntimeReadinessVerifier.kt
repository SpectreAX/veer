package com.yamax.veer.core_mihomo

import kotlinx.coroutines.delay

internal data class RuntimeReadinessEvidence(
    val nativeRuntimeReady: Boolean,
    val controllerReady: Boolean,
) {
    val ready: Boolean
        get() = nativeRuntimeReady && controllerReady
}

internal sealed interface RuntimeReadinessResult {
    data class Ready(
        val attempts: Int,
        val evidence: RuntimeReadinessEvidence,
    ) : RuntimeReadinessResult

    data class TimedOut(
        val attempts: Int,
        val lastEvidence: RuntimeReadinessEvidence,
    ) : RuntimeReadinessResult

    data class Cancelled(
        val attempts: Int,
        val lastEvidence: RuntimeReadinessEvidence,
    ) : RuntimeReadinessResult
}

/**
 * Bounded, testable readiness gate used after the native Start call returns.
 *
 * A localhost controller response alone is insufficient: the HTTP listener can
 * be accepting requests before the runtime proxy tree is installed. Conversely,
 * a populated proxy tree does not prove that the controller used by the UI and
 * watchdog is reachable. Running is publishable only when both observations
 * succeed in the same attempt.
 */
internal class RuntimeReadinessVerifier(
    private val maxAttempts: Int,
    private val retryDelayMs: Long,
    private val probe: suspend () -> RuntimeReadinessEvidence,
    private val isCancelled: () -> Boolean = { false },
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    init {
        require(maxAttempts > 0) { "maxAttempts must be positive" }
        require(retryDelayMs >= 0L) { "retryDelayMs must not be negative" }
    }

    suspend fun await(): RuntimeReadinessResult {
        var last = RuntimeReadinessEvidence(false, false)
        repeat(maxAttempts) { index ->
            val attempt = index + 1
            if (isCancelled()) {
                return RuntimeReadinessResult.Cancelled(index, last)
            }
            last = probe()
            if (last.ready) {
                return RuntimeReadinessResult.Ready(attempt, last)
            }
            if (attempt < maxAttempts) pause(retryDelayMs)
        }
        return RuntimeReadinessResult.TimedOut(maxAttempts, last)
    }
}
