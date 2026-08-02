package com.yamax.veer.testing

import android.content.Context
import android.os.Bundle
import com.yamax.veer.core_mihomo.ipc.ProcessRole
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
    @Volatile private var appContext: Context? = null

    fun install(context: Context) {
        appContext = context.applicationContext
    }

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

    /** True only when the loaded AAR contains the shutdown-hang fault hook. */
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
        if (useRemoteControl()) {
            remoteCall(DebugCoreControlProtocol.METHOD_FIRE_ALL_NETWORKS_LOST)
        } else {
            VeerVpnService.debugAllNetworksLostCallback?.invoke()
        }
    }

    // -------------------------------------------------------------------------
    // Timing overrides (VeerVpnService companion vars)
    // -------------------------------------------------------------------------

    /**
     * Overrides the watchdog initial delay for the duration of one test.
     * Call [resetTimings] in @After to restore defaults.
     */
    fun setWatchdogTimings(initialDelayMs: Long, intervalMs: Long) {
        if (useRemoteControl()) {
            remoteCall(
                DebugCoreControlProtocol.METHOD_SET_WATCHDOG_TIMINGS,
                Bundle().apply {
                    putLong(DebugCoreControlProtocol.KEY_INITIAL_DELAY_MS, initialDelayMs)
                    putLong(DebugCoreControlProtocol.KEY_INTERVAL_MS, intervalMs)
                },
            )
        } else {
            VeerVpnService.testWatchdogInitialDelayMs = initialDelayMs
            VeerVpnService.testWatchdogIntervalMs = intervalMs
        }
    }

    /** Overrides the onDestroy stop timeout. Call [resetTimings] in @After. */
    fun setStopTimeout(timeoutMs: Long) {
        if (useRemoteControl()) {
            remoteCall(
                DebugCoreControlProtocol.METHOD_SET_STOP_TIMEOUT,
                Bundle().apply {
                    putLong(DebugCoreControlProtocol.KEY_TIMEOUT_MS, timeoutMs)
                },
            )
        } else {
            VeerVpnService.testStopTimeoutMs = timeoutMs
        }
    }

    fun resetTimings() {
        if (useRemoteControl()) {
            remoteCall(DebugCoreControlProtocol.METHOD_RESET_TIMINGS)
            return
        }
        VeerVpnService.testWatchdogInitialDelayMs = -1L
        VeerVpnService.testWatchdogIntervalMs     = -1L
        VeerVpnService.testStopTimeoutMs          = -1L
        VeerVpnService.testAutoRecoveryInitialDelayMs = -1L
        VeerVpnService.testAutoRecoveryIntervalMs = -1L
        VeerVpnService.testAutoRecoveryFailureThreshold = -1
        VeerVpnService.testAutoRecoveryMaxCandidates = -1
        VeerVpnService.testAutoRecoveryInternetProbe = null
        VeerVpnService.testAutoRecoveryExhaustedCallback = null
        directRecoveryExhausted = false
    }

    fun configureExhaustedAutoRecovery() {
        if (useRemoteControl()) {
            remoteCall(DebugCoreControlProtocol.METHOD_CONFIGURE_EXHAUSTED_RECOVERY)
            return
        }
        VeerVpnService.testAutoRecoveryInitialDelayMs = 200L
        VeerVpnService.testAutoRecoveryIntervalMs = 300L
        VeerVpnService.testAutoRecoveryFailureThreshold = 2
        VeerVpnService.testAutoRecoveryMaxCandidates = 1
        VeerVpnService.testAutoRecoveryInternetProbe = { false }
        directRecoveryExhausted = false
        VeerVpnService.testAutoRecoveryExhaustedCallback = {
            directRecoveryExhausted = true
        }
    }

    fun isAutoRecoveryExhausted(): Boolean {
        if (useRemoteControl()) {
            return remoteCall(DebugCoreControlProtocol.METHOD_RECOVERY_STATUS)
                ?.getBoolean(DebugCoreControlProtocol.KEY_RECOVERY_EXHAUSTED)
                ?: false
        }
        return directRecoveryExhausted
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
        if (useRemoteControl()) {
            remoteCall(
                DebugCoreControlProtocol.METHOD_NATIVE,
                Bundle().apply {
                    putString(DebugCoreControlProtocol.KEY_NATIVE_METHOD, name)
                    putStringArrayList(
                        DebugCoreControlProtocol.KEY_NATIVE_ARGUMENTS,
                        ArrayList(args.map(Any::toString)),
                    )
                },
            )
            return
        }
        runCatching {
            Veercore::class.java.methods
                .firstOrNull { it.name == name && it.parameterCount == args.size }
                ?.invoke(null, *args)
        }
    }

    private fun goLong(name: String): Long {
        if (useRemoteControl()) {
            val bundle = remoteCall(DebugCoreControlProtocol.METHOD_COUNTERS)
            return when (name) {
                "getStartCallCount" ->
                    bundle?.getInt(DebugCoreControlProtocol.KEY_START_CALL_COUNT)?.toLong()
                "getStopCallCount" ->
                    bundle?.getInt(DebugCoreControlProtocol.KEY_STOP_CALL_COUNT)?.toLong()
                else -> null
            } ?: 0L
        }
        return runCatching {
            (Veercore::class.java.getMethod(name).invoke(null) as? Number)?.toLong()
        }.getOrNull() ?: 0L
    }

    private fun useRemoteControl(): Boolean =
        appContext != null && !ProcessRole.isCoreProcess()

    private fun remoteCall(method: String, extras: Bundle? = null): Bundle? =
        runCatching {
            appContext?.contentResolver?.call(
                DebugCoreControlProtocol.URI,
                method,
                null,
                extras,
            )
        }.getOrNull()

    @Volatile private var directRecoveryExhausted = false
}
