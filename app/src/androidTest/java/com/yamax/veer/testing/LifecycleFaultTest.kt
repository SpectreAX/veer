package com.yamax.veer.testing

import android.content.Context
import android.net.VpnService
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.BuildConfig
import com.yamax.veer.core_diagnostics.DiagnosticCheckStatus
import com.yamax.veer.core_diagnostics.DiagnosticCategory
import com.yamax.veer.core_diagnostics.NetworkDiagnosticExecutor
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.StartupStage
import com.yamax.veer.core_mihomo.VeerVpnService
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Empirical validation of VeerVpnService lifecycle invariants.
 *
 * Prerequisites:
 *   1. Run on a physical device or emulator with VPN permission pre-granted.
 *      Most tests call [checkVpnPrepared] and skip via [assumeTrue] when
 *      VPN consent is absent so CI does not hard-fail on unconfigured runners.
 *   2. For fault-injection tests, the debug .aar must be built:
 *        cd go_core && make aar-debug
 *      Tests that require it call [assumeFaultInjectAar] and skip gracefully
 *      when the production noop .aar is loaded.
 *
 * Run the suite with:
 *   ./gradlew :app:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.class=\
 *     com.yamax.veer.testing.LifecycleFaultTest
 */
@RunWith(AndroidJUnit4::class)
class LifecycleFaultTest {

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private val ctx: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    /**
     * Skips the calling test when VPN permission has not been granted. This
     * avoids hard failures on CI runners where the user-consent dialog cannot
     * be automated.
     */
    private fun checkVpnPrepared() {
        val intent = VpnService.prepare(ctx)
        assumeTrue(
            "VPN consent not pre-granted — run the app and approve the VPN dialog first",
            intent == null,
        )
    }

    /**
     * Guards the test when a non-fault-injection AAR is loaded. The packaged
     * debug AAR provides setFaultHangBeforeShutdown; the assumption keeps
     * ad-hoc release-AAR runs from being reported as product failures.
     */
    private fun assumeShutdownHangAvailable() {
        assumeTrue(
            "setFaultHangBeforeShutdown requires the fault-injection debug AAR",
            FaultInjector.isShutdownHangAvailable,
        )
    }

    /**
     * Skips the calling test when the production noop .aar is loaded.
     * Detected by [GoroutineInventory.isAvailable] which checks that the Go
     * runtime reports a non-zero goroutine count.
     */
    private fun assumeFaultInjectAar() {
        assumeTrue(
            "Fault injection requires debug .aar — run `make aar-debug` in go_core/ first",
            BuildConfig.FAULT_INJECT && GoroutineInventory.isAvailable,
        )
    }

    /** Suspends until [predicate] holds or [timeoutMs] elapses. Returns null on timeout. */
    private suspend fun <T : EngineState> awaitState(
        klass: Class<T>,
        timeoutMs: Long = 8_000L,
    ): T? = withTimeoutOrNull(timeoutMs) {
        @Suppress("UNCHECKED_CAST")
        MihomoEngine.state.first { klass.isInstance(it) } as T
    }

    private fun startVpn() = ctx.startForegroundService(VeerVpnService.startIntent(ctx))
    private fun stopVpn()  = ctx.startForegroundService(VeerVpnService.stopIntent(ctx))
    private fun reconnectVpn() =
        ctx.startForegroundService(VeerVpnService.reconnectIntent(ctx))

    // -------------------------------------------------------------------------
    // Test lifecycle
    // -------------------------------------------------------------------------

    companion object {
        @BeforeClass
        @JvmStatic
        fun installObserver() {
            DebugLifecycleSetup.install(
                InstrumentationRegistry.getInstrumentation().targetContext,
            )
        }
    }

    @Before
    fun setUp() {
        FaultInjector.clearAll()
        // Ensure service is stopped before each test.
        runBlocking {
            if (MihomoEngine.state.value !is EngineState.Stopped) {
                InstrumentationRegistry.getInstrumentation()
                    .targetContext
                    .startForegroundService(VeerVpnService.stopIntent(
                        InstrumentationRegistry.getInstrumentation().targetContext))
                withTimeoutOrNull(6_000L) {
                    MihomoEngine.state.first { it is EngineState.Stopped }
                }
            }
        }
        PhaseTrace.clear()
        FaultInjector.resetCallCounts()
    }

    @After
    fun tearDown() {
        FaultInjector.clearAll()
        // Best-effort cleanup: stop the service regardless of test outcome.
        runBlocking {
            if (MihomoEngine.state.value !is EngineState.Stopped) {
                ctx.startForegroundService(VeerVpnService.stopIntent(ctx))
                withTimeoutOrNull(8_000L) {
                    MihomoEngine.state.first { it is EngineState.Stopped }
                }
            }
        }
    }

    // =========================================================================
    // Test 1 — WaitReady timeout path
    //
    // Validates: §4.4 (JNI non-cancellable), §2.4 (forced close on timeout),
    //            STOP_TIMEOUT_MS enforcement, state reaches Stopped.
    //
    // Procedure: inject a release-controlled hang on ApplyConfig; wait for JNI
    // entry; stop with a 2 s outer timeout. The JVM TUN is force-closed, but
    // state remains truthfully Stopping until the hang is released and the
    // mandatory late-start cleanup pass completes.
    // =========================================================================
    @Test(timeout = 30_000)
    fun hangStartTimeoutPath() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        // A release-controlled gate makes the timeout deterministic and lets the
        // test wait for full native drainage instead of leaking work into the
        // following test.
        FaultInjector.hangBeforeApplyConfig(durationMs = -1L)
        FaultInjector.setStopTimeout(timeoutMs = 2_000L)

        var stopRequestedMs = 0L
        startVpn()

        runBlocking {
            val nativeStartEntered = withTimeoutOrNull(10_000L) {
                while (FaultInjector.startCallCount < 1) delay(25L)
                true
            } ?: false
            assertTrue("Native Start did not enter the injected hang", nativeStartEntered)

            // Trigger shutdown while start is hanging.
            stopRequestedMs = System.currentTimeMillis()
            stopVpn()

            delay(2_500L)
            assertTrue(
                "Runtime must remain Stopping while native Start is blocked: " +
                    PhaseTrace.stateNames(),
                MihomoEngine.state.value is EngineState.Stopping,
            )
        }

        val elapsedMs = System.currentTimeMillis() - stopRequestedMs
        // The stop timeout is 2 s. Total elapsed must be well under 5 s
        // (the hang duration) — confirming the timeout fired, not the hang expiry.
        assertTrue(
            "Timeout path took ${elapsedMs}ms — expected < 5000ms (timeout must have fired)",
            elapsedMs < 5_000L,
        )

        // Unblock JNI, then require bootCore's late-start cleanup to call the
        // native stop path. Cross-process StateFlow transport intentionally
        // conflates consecutive identical Stopped snapshots, so a second UI
        // frame is not a valid cleanup signal after process isolation.
        FaultInjector.releaseApplyConfigHang()
        val lateCleanupObserved = runBlocking {
            withTimeoutOrNull(5_000L) {
                while (FaultInjector.stopCallCount < 1) delay(25L)
                true
            }
        } ?: false
        assertTrue(
            "Late-start cleanup did not complete: ${PhaseTrace.stateNames()}",
            lateCleanupObserved,
        )
        assertEquals(
            "Late-start cleanup must call Veercore.stop() exactly once",
            1,
            FaultInjector.stopCallCount,
        )
        runBlocking {
            assertNotNull(
                "Service did not reach Stopped after late cleanup",
                awaitState(EngineState.Stopped::class.java, timeoutMs = 5_000L),
            )
        }
        assertTrue(
            "Expected phase sequence Stopping → Stopped in trace: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Stopped"),
        )
    }

    @Test(timeout = 30_000)
    fun startupProgressTracksNativeRuntimeGate() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        FaultInjector.hangBeforeApplyConfig(durationMs = -1L)
        startVpn()

        runBlocking {
            assertNotNull(
                "Service did not reach Starting",
                awaitState(EngineState.Starting::class.java, timeoutMs = 4_000L),
            )
            val runtimeStage = withTimeoutOrNull(5_000L) {
                MihomoEngine.startupStage.first {
                    it == StartupStage.STARTING_RUNTIME
                }
            }
            assertEquals(
                "Progress must identify the native runtime while ApplyConfig is blocked",
                StartupStage.STARTING_RUNTIME,
                runtimeStage,
            )

            FaultInjector.releaseApplyConfigHang()
            assertNotNull(
                "Service did not reach Running after releasing ApplyConfig",
                awaitState(EngineState.Running::class.java, timeoutMs = 12_000L),
            )
            val idleStage = withTimeoutOrNull(2_000L) {
                MihomoEngine.startupStage.first { it == StartupStage.IDLE }
            }
            assertEquals(
                "Startup progress mirror must reset after the engine leaves Starting",
                StartupStage.IDLE,
                idleStage,
            )
        }
    }

    // =========================================================================
    // Test 2 — Failed startup cleanup (V1 fix: startAttempted flag)
    //
    // Validates: native_runtime_contract V1 — when Veercore.start() returns an
    // error, tearDownCore() must still call Veercore.stop() because
    // startAttempted was set to true before the call. Without the V1 fix,
    // stopCallCount would be 0 here.
    // =========================================================================
    @Test(timeout = 25_000)
    fun failedStartupCallsStop() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        FaultInjector.errorBeforeApplyConfig("injected-start-failure")

        runBlocking {
            // Start collecting before dispatching the service intent. Starting
            // and Error can be only milliseconds apart, and StateFlow correctly
            // conflates transient values for late subscribers.
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Error::class.java, timeoutMs = 12_000L)
            }
            startVpn()
            val error = errorWait.await()
            assertNotNull("Service did not expose the injected startup error", error)
            val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 10_000L)
            assertNotNull("Service did not reach Stopped after injected start failure", stopped)
        }

        assertTrue(
            "Expected Starting → Error in trace: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Starting", "Error"),
        )
        assertTrue(
            "Expected Stopping → Stopped in trace: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Stopped"),
        )

        // The V1 invariant: tearDownCore called Veercore.stop() even though
        // Veercore.start() never returned success (coreRunning was never set true).
        assertEquals(
            "Veercore.start() should be called exactly once",
            1,
            FaultInjector.startCallCount,
        )
        assertEquals(
            "Veercore.stop() must be called once (V1 fix: startAttempted ensures cleanup)",
            1,
            FaultInjector.stopCallCount,
        )
    }

    // =========================================================================
    // Test 3 — Panic on the JNI goroutine is caught, cleanup still runs
    //
    // Validates: the defer recover() in Veercore.Start() surfaces the panic as
    // a Java exception; bootCore's runCatching handles it; the same V1 cleanup
    // path fires as in Test 2.
    // =========================================================================
    @Test(timeout = 25_000)
    fun jniGoroutinePanicCaughtByRecover() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        FaultInjector.panicOnJniGoroutine("injected-jni-panic")

        runBlocking {
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Error::class.java, timeoutMs = 12_000L)
            }
            startVpn()
            val error = errorWait.await()
            assertNotNull("Service did not expose the JNI panic", error)
            val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 10_000L)
            assertNotNull("Service did not reach Stopped after JNI panic", stopped)
        }

        // Panic surfaced as an exception, bootCore treated it as a start failure.
        assertTrue(
            "Expected Starting → Error in trace: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Starting", "Error"),
        )
        val errorState = PhaseTrace.peek()
            .firstOrNull { it.stateName == "Error" }
        assertNotNull("Error state must be recorded", errorState)

        // V1 cleanup: stop was called despite the panic.
        assertEquals(1, FaultInjector.stopCallCount)
    }

    // =========================================================================
    // Test 4 — Concurrent start + stop serialised by engineMutex (§1.4)
    //
    // Validates: rapid ACTION_START → ACTION_STOP produces exactly one
    // Veercore.start() call and exactly one Veercore.stop() call. The short
    // hang gives tearDownCore a window to see bootCore holding the mutex and
    // block on it rather than running a second start path.
    // =========================================================================
    @Test(timeout = 15_000)
    fun concurrentStartStopSerializedByMutex() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        // 300 ms hang gives the stop intent time to arrive while start is
        // still inside engineMutex, exercising the mutex-wait path in tearDownCore.
        FaultInjector.hangBeforeApplyConfig(durationMs = 300L)

        startVpn()

        // Wait for the native call itself rather than assuming the main process,
        // :veercore process and config preparation all complete within 50 ms.
        // This keeps the test deterministic on cold emulators while preserving
        // the intended race: Stop arrives while Start owns engineMutex at the
        // injected pre-ApplyConfig hang.
        val nativeStartEntered = runBlocking {
            withTimeoutOrNull(5_000L) {
                while (FaultInjector.startCallCount < 1) delay(10L)
                true
            }
        } ?: false
        assertTrue("Native Start did not enter the injected hang", nativeStartEntered)
        stopVpn()

        runBlocking {
            withTimeoutOrNull(10_000L) {
                while (FaultInjector.stopCallCount < 1) delay(10L)
            }
            val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 10_000L)
            assertNotNull("Service did not reach Stopped", stopped)
        }

        // The mutex invariant: exactly one start path and one stop path executed.
        assertEquals(
            "Expected exactly one Veercore.start() call, got ${FaultInjector.startCallCount}",
            1,
            FaultInjector.startCallCount,
        )
        assertEquals(
            "Expected exactly one Veercore.stop() call, got ${FaultInjector.stopCallCount}",
            1,
            FaultInjector.stopCallCount,
        )

        // No "Running" state must have occurred — the error from the hang returned
        // before ApplyConfig could complete.
        assertEquals(
            "Running state must not have been reached when start returned via hang+stop",
            0,
            PhaseTrace.countOf("Running"),
        )

        // Exactly one Stopping and one Stopped.
        assertEquals(1, PhaseTrace.countOf("Stopping"))
        assertEquals(1, PhaseTrace.countOf("Stopped"))
    }

    // =========================================================================
    // Start → stop during JNI startup → immediate start
    //
    // The final START is user intent, not a duplicate of the first command. It
    // must wait for the in-flight runtime to drain and then start exactly once.
    // =========================================================================
    @Test(timeout = 40_000)
    fun startStopImmediateStartQueuesUntilSafeDrain() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        FaultInjector.hangBeforeApplyConfig(durationMs = 300L)
        startVpn()
        runBlocking {
            val starting = awaitState(EngineState.Starting::class.java, timeoutMs = 4_000L)
            assertNotNull("Initial start did not enter Starting", starting)
        }

        stopVpn()
        startVpn()

        runBlocking {
            // A cold arm64 emulator may spend several seconds loading the Go
            // runtime before the injected delay is reached. Cover two complete
            // starts plus the bounded late-cleanup handoff, while the method's
            // outer timeout still fails a genuinely stuck restart.
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 25_000L)
            assertNotNull(
                "Queued start did not resume after safe drain: ${PhaseTrace.stateNames()}",
                running,
            )
        }

        assertEquals(
            "Expected the original and queued starts only",
            2,
            FaultInjector.startCallCount,
        )
        assertEquals(
            "The interrupted runtime must be stopped exactly once",
            1,
            FaultInjector.stopCallCount,
        )
        assertEquals(
            "A normal start-stop-start race must not surface Error",
            0,
            PhaseTrace.countOf("Error"),
        )
    }

    // =========================================================================
    // Exhausted proxy recovery is data-plane degradation, not a core crash
    // =========================================================================
    @Test(timeout = 30_000)
    fun exhaustedAutoRecoveryKeepsRuntimeRunning() {
        checkVpnPrepared()

        FaultInjector.configureExhaustedAutoRecovery()

        startVpn()
        runBlocking {
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
            assertNotNull("Service did not reach Running", running)
        }

        val exhausted = runBlocking {
            withTimeoutOrNull(15_000L) {
                while (!FaultInjector.isAutoRecoveryExhausted()) delay(50L)
                true
            }
        } ?: false
        assertTrue("Auto recovery did not reach the exhausted path", exhausted)
        Thread.sleep(500L)

        assertTrue(
            "Candidate exhaustion must keep the healthy core/TUN alive",
            MihomoEngine.state.value is EngineState.Running,
        )
        assertEquals(
            "Candidate exhaustion must not be reported as a runtime crash",
            0,
            PhaseTrace.countOf("Error"),
        )
    }

    // =========================================================================
    // Test 5 — In-service reconnect skips Android service destruction
    //
    // Validates: Running → Stopping → Starting → Running completes through the
    // single service-owned runtime path without publishing an intermediate
    // Stopped state or creating overlapping native runtimes.
    // =========================================================================
    @Test(timeout = 20_000)
    fun inServiceReconnectCompletesWithoutStoppedFrame() {
        checkVpnPrepared()

        startVpn()
        runBlocking {
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
            assertNotNull("Service did not reach Running before reconnect", running)
        }
        PhaseTrace.clear()

        val startedAt = System.currentTimeMillis()
        runBlocking {
            // Register all three collectors before dispatch. Reconnect is often
            // fast enough that Starting can be published while the test is
            // still awaiting Stopping; StateFlow intentionally does not replay
            // that transient value to a later sequential collector.
            val stoppingWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Stopping::class.java, timeoutMs = 2_000L)
            }
            val startingWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Starting::class.java, timeoutMs = 4_000L)
            }
            val runningWait = async(start = CoroutineStart.UNDISPATCHED) {
                // Ignore the currently running pre-reconnect generation and
                // wait specifically for the next Running publication.
                withTimeoutOrNull(8_000L) {
                    MihomoEngine.state
                        .drop(1)
                        .first { it is EngineState.Running } as EngineState.Running
                }
            }

            reconnectVpn()

            val stopping = stoppingWait.await()
            assertNotNull("Reconnect did not enter Stopping", stopping)
            val starting = startingWait.await()
            assertNotNull("Reconnect did not enter Starting", starting)
            val running = runningWait.await()
            assertNotNull("Reconnect did not return to Running", running)
        }

        assertTrue(
            "Reconnect exceeded 10 seconds",
            System.currentTimeMillis() - startedAt < 10_000L,
        )
        assertTrue(
            "Expected Stopping → Starting → Running: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Starting", "Running"),
        )
        assertEquals(
            "Fast reconnect must not expose a user-clickable Stopped frame",
            0,
            PhaseTrace.countOf("Stopped"),
        )
    }

    // =========================================================================
    // Test 6 — Goroutine count stable across N restart cycles
    //
    // Validates: no goroutine leak accumulates across repeated start/stop cycles
    // (Scenarios 3 and 8 partial-mitigation verification).
    // Requires the debug .aar for a real goroutine count; skips otherwise.
    // =========================================================================
    @Test(timeout = 120_000)
    fun goroutineCountStableAfterRestarts() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        // Warm the process-global Mihomo UDP worker pool before taking the
        // baseline. Those workers are initialized once and intentionally live
        // for the whole app process; the measured cycles below must not add
        // any further long-lived goroutines.
        startVpn()
        runBlocking {
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
            assertNotNull("Warm-up: did not reach Running", running)
            stopVpn()
            val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 10_000L)
            assertNotNull("Warm-up: did not reach Stopped", stopped)
        }
        Thread.sleep(1_000)
        val baseline = GoroutineInventory.take()

        fun runCycles(cycles: Int, label: String) {
            repeat(cycles) { i ->
                startVpn()
                runBlocking {
                    val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
                    assertNotNull("$label cycle ${i + 1}: did not reach Running", running)
                    stopVpn()
                    val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 10_000L)
                    assertNotNull("$label cycle ${i + 1}: did not reach Stopped", stopped)
                }
                // Give goroutines time to drain between cycles.
                Thread.sleep(500)
            }
        }

        val cycles = 5
        runCycles(cycles, "Measured")

        val after = runBlocking {
            // Mihomo closes some provider/check goroutines asynchronously after
            // the core and TUN have reached Stopped. Poll long enough to
            // distinguish eventual drainage from an accumulating leak.
            GoroutineInventory.awaitDelta(baseline, timeoutMs = 10_000L) { delta ->
                delta <= 2
            }
        }

        val firstDelta = GoroutineInventory.delta(baseline, after)
        val firstDiagnosticStacks = if (firstDelta > 8) {
            GoroutineInventory.take(includeStacks = true).stacks.take(12_000)
        } else {
            ""
        }
        assertTrue(
            "Unbounded goroutine growth detected in the first $cycles cycles: " +
                "delta=$firstDelta (baseline=${baseline.count}, after=${after.count}). " +
                "Remaining goroutines:\n$firstDiagnosticStacks",
            firstDelta <= 8,
        )

        // gomobile and the HTTP stack may create a small bounded worker/transport
        // set only after a fault-heavy suite has exercised several protocol paths.
        // A real restart leak continues growing in a second batch; a bounded pool
        // does not. This caught the previous +24-per-cycle dial leak while avoiding
        // a false failure from one-time runtime warm-up.
        var finalAfter = after
        var stabilizedDelta = 0
        val confirmationCycles = if (firstDelta > 2) 3 else 0
        if (confirmationCycles > 0) {
            runCycles(confirmationCycles, "Confirmation")
            finalAfter = runBlocking {
                GoroutineInventory.awaitDelta(after, timeoutMs = 10_000L) { delta ->
                    delta <= 2
                }
            }
            stabilizedDelta = GoroutineInventory.delta(after, finalAfter)
        }

        val diagnosticStacks = if (stabilizedDelta > 2) {
            GoroutineInventory.take(includeStacks = true).stacks.take(12_000)
        } else {
            ""
        }
        assertTrue(
            "Goroutine leak detected after stabilization: firstDelta=$firstDelta, " +
                "confirmationDelta=$stabilizedDelta after $confirmationCycles cycles " +
                "(final=${finalAfter.count}). Remaining goroutines:\n$diagnosticStacks",
            stabilizedDelta <= 2,
        )
    }

    // =========================================================================
    // Test 7 — EngineState.Error message is non-empty after injected failure
    //
    // Validates: §6.1 — all failures produce observable state with a message.
    // Does not require VPN permission (error injected before ApplyConfig, after
    // the tun is established — permission still required for establish()).
    // =========================================================================
    @Test(timeout = 25_000)
    fun errorStateCarriesMessage() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        val injectedMsg = "error-message-visibility-check"
        FaultInjector.errorBeforeApplyConfig(injectedMsg)

        val errorState = runBlocking {
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Error::class.java, timeoutMs = 12_000L)
            }
            startVpn()
            errorWait.await()
        }
        assertNotNull("EngineState.Error was not reached", errorState)
        assertTrue(
            "Error message is empty — §6.1 requires observable failure cause",
            errorState!!.message.isNotEmpty(),
        )

        // Wait for teardown to complete before tearDown() runs.
        runBlocking {
            awaitState(EngineState.Stopped::class.java, timeoutMs = 8_000L)
        }
    }

    // =========================================================================
    // Test 8 — Phase transition observer is installed and fires
    //
    // Validates: DebugLifecycleSetup.install() wires PhaseTrace correctly;
    // MihomoEngine.stateObserver != null; every setState call is captured.
    // Does not require VPN permission — state is set directly here.
    // =========================================================================
    @Test
    fun phaseTraceObserverFires() {
        PhaseTrace.clear()

        // Drive a state transition directly without starting the service.
        // This validates the observer wire-up independently of VPN permission.
        MihomoEngine.setState(EngineState.Starting)
        MihomoEngine.setState(EngineState.Running)
        MihomoEngine.setState(EngineState.Stopping)
        MihomoEngine.setState(EngineState.Stopped)

        val names = PhaseTrace.stateNames()
        assertEquals(
            "PhaseTrace must record all four transitions",
            listOf("Starting", "Running", "Stopping", "Stopped"),
            names,
        )
        assertTrue(PhaseTrace.containsSequence("Starting", "Running", "Stopping", "Stopped"))

        // Restore to Stopped so tearDown() cleanup loop finds the service stopped.
        MihomoEngine.setState(EngineState.Stopped)
    }

    // =========================================================================
    // Test 9 — MihomoEngine.setState is inaccessible from outside core_mihomo
    //
    // This is a compile-time assertion encoded as a runtime check. If this test
    // reaches its body, setState is callable from the test package — which means
    // the internal visibility invariant (§3.3) is being enforced only because
    // androidTest compiles within the app module. The comment below is the check.
    //
    // For a stricter enforcement, see the CI static-analysis job in
    // runtime_validation_harness.md §9.2.
    // =========================================================================
    @Test
    fun stateObserverIsInternalToModule() {
        // MihomoEngine.setState is `internal`. We can call it here because
        // androidTest compiles within the same module. The static-analysis grep
        // in CI ensures no production source outside core_mihomo calls it.
        // This test verifies the @Volatile stateObserver field is wired (non-null
        // after DebugLifecycleSetup.install()) and that direct setState calls
        // appear in PhaseTrace — confirming the observer is invoked.
        PhaseTrace.clear()
        MihomoEngine.setState(EngineState.Error("test"))
        val recorded = PhaseTrace.peek().any { it.stateName == "Error" }
        assertTrue("stateObserver must fire on every setState call", recorded)
        MihomoEngine.setState(EngineState.Stopped)
    }

    // =========================================================================
    // Test 10 — JNI stop timeout → EngineState.Error (F2 / §3.2 Stopping→Error)
    //
    // Validates: Layer 2 CountDownLatch (STOP_JNI_TIMEOUT_MS = 5 s) fires when
    // Veercore.stop() hangs, and the terminal state is Error NOT Stopped.
    //
    // Capability-guarded when an ad-hoc build loads a non-fault-injection AAR.
    // testStopTimeoutMs is raised above STOP_JNI_TIMEOUT_MS so Layer 1
    // (withTimeoutOrNull) does not preempt the JNI latch.
    // =========================================================================
    @Test(timeout = 30_000)
    fun jniStopTimeoutTransitionsToError() {
        checkVpnPrepared()
        assumeFaultInjectAar()
        assumeShutdownHangAvailable()

        FaultInjector.hangBeforeShutdown(-1L)
        // Layer 1 must not preempt Layer 2: set outer timeout > STOP_JNI_TIMEOUT_MS (5 s).
        FaultInjector.setStopTimeout(12_000L)

        startVpn()

        runBlocking {
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
            assertNotNull("Service did not reach Running within 12 s", running)

            stopVpn()

            // Layer 2 fires after STOP_JNI_TIMEOUT_MS (5 s). Allow 3 s margin.
            val error = awaitState(EngineState.Error::class.java, timeoutMs = 9_000L)
            assertNotNull(
                "Service did not transition to Error after JNI stop timeout — " +
                "trace: ${PhaseTrace.stateNames()}",
                error,
            )
            assertTrue(
                "Error message must describe stop timeout: '${error!!.message}'",
                error.message.contains("timed out", ignoreCase = true),
            )
        }

        assertTrue(
            "Expected Stopping → Error in trace: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Error"),
        )
        assertFalse(
            "Stopping → Stopped must NOT appear on JNI timeout path: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Stopped"),
        )

        // Unblock the orphaned daemon thread so it doesn't linger into subsequent tests.
        FaultInjector.releaseShutdownHang()
    }

    // =========================================================================
    // Test 11 — Late connectivity callback takes "teardown in progress" branch (F1)
    //
    // Validates: coreRunning=false is written before connectivityMonitor.stop()
    // (F1 fix), so an onAllNetworksLost callback that arrives during teardown
    // sees coreRunning=false and takes the else branch — no setState(Error),
    // no spurious stopSelf(), clean Stopping→Stopped transition.
    //
    // Procedure: reach Running, start stop, then fire the callback synthetically
    // once Stopping is observed (giving tearDownCore time to write coreRunning=false).
    // =========================================================================
    @Test(timeout = 25_000)
    fun lateConnCallbackTakesTeardownBranch() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        startVpn()

        runBlocking {
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
            assertNotNull("Service did not reach Running within 12 s", running)
        }

        // Arm a one-shot debug probe at the exact teardown boundary. A fixed
        // sleep here is inherently flaky because a fast native shutdown can
        // unregister and clear the callback before the test thread wakes up.
        FaultInjector.armTeardownConnectivityProbe()

        stopVpn()

        runBlocking {
            val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 12_000L)
            assertNotNull("Service did not reach Stopped after normal stop: ${PhaseTrace.stateNames()}", stopped)
        }

        assertTrue(
            "Callback was never fired at the connectivity teardown boundary",
            FaultInjector.wasTeardownConnectivityProbeFired(),
        )

        // F1 invariant: the late callback must have taken the else branch (coreRunning=false).
        // If it took the if-branch, it would have called setState(Error) → Error appears in trace.
        assertEquals(
            "Late connectivity callback during teardown must not produce Error state — " +
            "F1 fix (coreRunning=false before CM.stop()) must have been effective. " +
            "Trace: ${PhaseTrace.stateNames()}",
            0,
            PhaseTrace.countOf("Error"),
        )
        assertTrue(
            "Expected clean Stopping → Stopped transition: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Stopped"),
        )
    }

    // =========================================================================
    // Physical-network outage is recoverable and must not destroy Mihomo/TUN.
    // =========================================================================
    @Test(timeout = 25_000)
    fun allNetworksLostKeepsRuntimeReadyForRecovery() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        startVpn()
        runBlocking {
            assertNotNull(
                "Service did not reach Running within 12 s",
                awaitState(EngineState.Running::class.java, timeoutMs = 12_000L),
            )
        }
        val stopCallsBefore = FaultInjector.stopCallCount
        PhaseTrace.clear()

        FaultInjector.fireAllNetworksLostCallback()
        Thread.sleep(750L)

        assertTrue(
            "A physical-network outage must retain the runtime for handoff recovery: " +
                PhaseTrace.stateNames(),
            MihomoEngine.state.value is EngineState.Running,
        )
        assertEquals(
            "Connectivity loss must not call native Stop",
            stopCallsBefore,
            FaultInjector.stopCallCount,
        )
        assertEquals(0, PhaseTrace.countOf("Error"))
        assertEquals(0, PhaseTrace.countOf("Stopping"))
    }

    // =========================================================================
    // AIDL death is observable and a desired Running generation is recovered.
    // =========================================================================
    @Test(timeout = 35_000)
    fun coreProcessCrashRebindsAndRestartsRuntime() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        startVpn()
        runBlocking {
            assertNotNull(
                "Service did not reach Running before process crash",
                awaitState(EngineState.Running::class.java, timeoutMs = 12_000L),
            )
        }
        PhaseTrace.clear()

        runBlocking {
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                withTimeoutOrNull(8_000L) {
                    MihomoEngine.status.first {
                        it.machineCode == "CORE_BINDER_DIED"
                    }
                }
            }
            val recoveredWait = async(start = CoroutineStart.UNDISPATCHED) {
                withTimeoutOrNull(20_000L) {
                    MihomoEngine.state
                        .drop(1)
                        .first { it is EngineState.Running }
                }
            }

            FaultInjector.backgroundPanic("injected-core-process-crash", delayMs = 200L)

            assertNotNull("AIDL death was not converted to a typed Error", errorWait.await())
            assertNotNull("Core process did not rebind and recover Running", recoveredWait.await())
        }

        assertTrue(MihomoEngine.state.value is EngineState.Running)
    }

    // =========================================================================
    // Real data-plane smoke: controller, DNS, rules, HTTP/TCP and SOCKS5 UDP.
    // =========================================================================
    @Test(timeout = 40_000)
    fun runtimeDataPlaneCoversDnsTcpUdpAndRules() {
        checkVpnPrepared()

        startVpn()
        runBlocking {
            assertNotNull(
                "Service did not reach readiness-gated Running",
                awaitState(EngineState.Running::class.java, timeoutMs = 12_000L),
            )
        }

        val report = runBlocking {
            NetworkDiagnosticExecutor(ctx).diagnose("example.com")
        }
        assertEquals("Layered diagnosis failed: ${report.summary}", DiagnosticCategory.HEALTHY, report.category)
        for (id in listOf("tun", "controller", "dns", "rule", "internet", "target")) {
            val check = report.checks.first { it.id == id }
            assertEquals("$id failed: ${check.detail}", DiagnosticCheckStatus.PASS, check.status)
        }
        assertTrue("SOCKS5 UDP DNS exchange failed", socks5UdpDnsQuery())
    }

    private fun socks5UdpDnsQuery(): Boolean = runCatching {
        Socket().use { control ->
            control.soTimeout = 4_000
            control.connect(InetSocketAddress("127.0.0.1", 7890), 3_000)
            control.getOutputStream().apply {
                write(byteArrayOf(0x05, 0x01, 0x00))
                flush()
            }
            check(control.getInputStream().readExactly(2).contentEquals(byteArrayOf(0x05, 0x00)))

            control.getOutputStream().apply {
                write(byteArrayOf(0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
                flush()
            }
            val reply = control.getInputStream()
            val header = reply.readExactly(4)
            check(header[0] == 0x05.toByte() && header[1] == 0x00.toByte())
            val relayAddress = when (header[3].toInt() and 0xff) {
                0x01 -> InetAddress.getByAddress(reply.readExactly(4))
                0x04 -> InetAddress.getByAddress(reply.readExactly(16))
                0x03 -> InetAddress.getByName(
                    String(reply.readExactly(reply.readExactly(1)[0].toInt() and 0xff)),
                )
                else -> error("unsupported SOCKS relay address")
            }
            val relayPortBytes = reply.readExactly(2)
            val relayPort = ((relayPortBytes[0].toInt() and 0xff) shl 8) or
                (relayPortBytes[1].toInt() and 0xff)
            val effectiveRelay = if (relayAddress.isAnyLocalAddress) {
                InetAddress.getByName("127.0.0.1")
            } else {
                relayAddress
            }

            val dnsQuery = byteArrayOf(
                0x56, 0x72, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x07,
                'e'.code.toByte(), 'x'.code.toByte(), 'a'.code.toByte(),
                'm'.code.toByte(), 'p'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
                0x03, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(), 0x00,
                0x00, 0x01, 0x00, 0x01,
            )
            val udpRequest = byteArrayOf(
                0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x35,
            ) + dnsQuery
            DatagramSocket().use { udp ->
                udp.soTimeout = 6_000
                udp.send(
                    DatagramPacket(
                        udpRequest,
                        udpRequest.size,
                        effectiveRelay,
                        relayPort,
                    ),
                )
                val buffer = ByteArray(2_048)
                val response = DatagramPacket(buffer, buffer.size)
                udp.receive(response)
                val dnsOffset = socksUdpPayloadOffset(buffer, response.length)
                check(response.length >= dnsOffset + 12)
                check(buffer[dnsOffset] == 0x56.toByte() && buffer[dnsOffset + 1] == 0x72.toByte())
                check(buffer[dnsOffset + 2].toInt() and 0x80 != 0)
            }
        }
        true
    }.getOrDefault(false)

    private fun socksUdpPayloadOffset(packet: ByteArray, length: Int): Int {
        check(length >= 4 && packet[2] == 0x00.toByte())
        return when (packet[3].toInt() and 0xff) {
            0x01 -> 10
            0x04 -> 22
            0x03 -> 7 + (packet[4].toInt() and 0xff)
            else -> error("unsupported SOCKS UDP address")
        }
    }

    private fun InputStream.readExactly(size: Int): ByteArray {
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = read(result, offset, size - offset)
            check(count > 0) { "unexpected EOF" }
            offset += count
        }
        return result
    }
}
