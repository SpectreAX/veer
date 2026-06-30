package com.yamax.veer.testing

import com.yamax.veer.core_mihomo.VeerVpnService
import veercore.Veercore

/**
 * Kotlin-side facade over the Go fault injection API and the Kotlin timing
 * overrides. All methods are no-ops if the production .aar is loaded (the Go
 * functions exist as stubs but do nothing; the Kotlin overrides write to
 * internal vars that are never read in release).
 *
 * Only compiled in the debug source set. Tests call this directly; production
 * code never references it.
 */
internal object FaultInjector {

    // -------------------------------------------------------------------------
    // Go-side ApplyConfig fault hooks
    // -------------------------------------------------------------------------

    /**
     * Installs a hang at the ApplyConfig hook point inside [veercore.Veercore.start].
     * [durationMs] < 0 blocks until [releaseApplyConfigHang]; > 0 sleeps for
     * that many ms; == 0 clears any existing hang.
     */
    fun hangBeforeApplyConfig(durationMs: Long = -1L) {
        goVoid("setFaultHangBeforeApplyConfig", durationMs)
    }

    /** Unblocks any goroutine suspended at the ApplyConfig hang gate. */
    fun releaseApplyConfigHang() {
        goVoid("releaseHangBeforeApplyConfig")
    }

    /**
     * Makes [veercore.Veercore.start] return an error at the ApplyConfig hook
     * without calling executor.ApplyConfig. Simulates a config-apply failure.
     * Pass "" to clear.
     */
    fun errorBeforeApplyConfig(message: String = "injected-applyconfig-error") {
        goVoid("setFaultErrorBeforeApplyConfig", message)
    }

    /**
     * Panics on the JNI-calling goroutine at the ApplyConfig hook. The panic is
     * caught by [veercore.Veercore.start]'s `defer recover()` and surfaces as a
     * Java exception, which [VeerVpnService.bootCore] handles via `runCatching`.
     * Pass "" to clear.
     */
    fun panicOnJniGoroutine(message: String = "injected-jni-goroutine-panic") {
        goVoid("setFaultPanicBeforeApplyConfig", message)
    }

    /**
     * Spawns a Go goroutine that panics after [delayMs]. That goroutine has NO
     * recover() — it terminates the process. Only call this when your test is
     * specifically designed to measure post-process-death recovery behavior.
     * Pass msg="" to cancel before the delay expires.
     */
    fun backgroundPanic(message: String = "injected-background-panic", delayMs: Long = 200L) {
        goVoid("setFaultBackgroundPanic", message, delayMs)
    }

    // -------------------------------------------------------------------------
    // Call counters (require debug .aar)
    // -------------------------------------------------------------------------

    val startCallCount: Int get() = goLong("getStartCallCount").toInt()
    val stopCallCount: Int  get() = goLong("getStopCallCount").toInt()

    fun resetCallCounts() = goVoid("resetCallCounts")

    // -------------------------------------------------------------------------
    // Go-side Shutdown fault hooks
    // -------------------------------------------------------------------------

    /**
     * Installs a hang at the Veercore.stop() / executor.Shutdown() hook point.
     * [durationMs] < 0 blocks until [releaseShutdownHang]; > 0 sleeps for that
     * many ms; == 0 clears. When active, [CountDownLatch.await] in tearDownCore
     * fires after STOP_JNI_TIMEOUT_MS → [EngineState.Error] (§3.2 Stopping→Error).
     */
    fun hangBeforeShutdown(durationMs: Long = -1L) {
        goVoid("setFaultHangBeforeShutdown", durationMs)
    }

    /** Unblocks any goroutine suspended at the Shutdown hang gate. */
    fun releaseShutdownHang() {
        goVoid("releaseHangBeforeShutdown")
    }

    /** True only when the loaded .aar contains the setFaultHangBeforeShutdown hook (SI-08). */
    val isShutdownHangAvailable: Boolean
        get() = Veercore::class.java.methods.any { it.name == "setFaultHangBeforeShutdown" }

    // -------------------------------------------------------------------------
    // Connectivity callback test controls
    // -------------------------------------------------------------------------

    /**
     * Invokes the [onAllNetworksLost] handler stored in
     * [VeerVpnService.debugAllNetworksLostCallback]. Use this to simulate a
     * late-arriving Binder callback that races with teardown. No-op if the
     * service has already nulled the callback in tearDownCore.
     */
    fun fireAllNetworksLostCallback() {
        VeerVpnService.debugAllNetworksLostCallback?.invoke()
    }

    // -------------------------------------------------------------------------
    // Timing overrides (VeerVpnService companion vars)
    // -------------------------------------------------------------------------

    /**
     * Overrides the watchdog initial delay for the duration of one test.
     * Call [resetTimings] in @After to restore defaults.
     */
    fun setWatchdogTimings(initialDelayMs: Long, intervalMs: Long) {
        VeerVpnService.testWatchdogInitialDelayMs = initialDelayMs
        VeerVpnService.testWatchdogIntervalMs     = intervalMs
    }

    /** Overrides the onDestroy stop timeout. Call [resetTimings] in @After. */
    fun setStopTimeout(timeoutMs: Long) {
        VeerVpnService.testStopTimeoutMs = timeoutMs
    }

    fun resetTimings() {
        VeerVpnService.testWatchdogInitialDelayMs = -1L
        VeerVpnService.testWatchdogIntervalMs     = -1L
        VeerVpnService.testStopTimeoutMs          = -1L
    }

    // -------------------------------------------------------------------------
    // Housekeeping
    // -------------------------------------------------------------------------

    /**
     * Removes all Go-side fault hooks, releases all hang gates, resets call
     * counters, and restores timing defaults. Call from @Before and @After to
     * ensure test isolation.
     */
    fun clearAll() {
        goVoid("clearAllFaults")
        resetTimings()
        PhaseTrace.clear()
    }

    // -------------------------------------------------------------------------
    // Reflection helpers — look up Go-bound static methods by name so this file
    // compiles against any .aar variant; silently no-op when the method is absent.
    // -------------------------------------------------------------------------

    private fun goVoid(name: String, vararg args: Any) {
        runCatching {
            Veercore::class.java.methods
                .firstOrNull { it.name == name && it.parameterCount == args.size }
                ?.invoke(null, *args)
        }
    }

    private fun goLong(name: String): Long = runCatching {
        Veercore::class.java.getMethod(name).invoke(null) as? Long
    }.getOrNull() ?: 0L
}
