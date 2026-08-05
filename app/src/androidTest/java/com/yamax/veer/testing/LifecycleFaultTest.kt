package com.yamax.veer.testing

import android.content.Context
import android.net.VpnService
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.BuildConfig
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
    // Procedure: inject a release-controlled hang on ApplyConfig; start VPN; immediately stop;
    // override stop timeout to 2 s. The 2 s timeout fires while bootCore holds
    // engineMutex (suspended inside Veercore.start), tearDownTun() is force-
    // called, state reaches Stopped. The test then releases JNI and verifies the
    // mandatory late-start cleanup pass before allowing the next test to begin.
    // =========================================================================
    @Test(timeout = 15_000)
    fun hangStartTimeoutPath() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        // A release-controlled gate makes the timeout deterministic and lets the
        // test wait for full native drainage instead of leaking work into the
        // following test.
        FaultInjector.hangBeforeApplyConfig(durationMs = -1L)
        FaultInjector.setStopTimeout(timeoutMs = 2_000L)

        val startMs = System.currentTimeMillis()
        startVpn()

        runBlocking {
            // Wait for Starting to confirm bootCore is running (and holding the mutex).
            val starting = awaitState(EngineState.Starting::class.java, timeoutMs = 4_000L)
            assertNotNull("Service did not reach Starting within 4 s", starting)

            // Trigger shutdown while start is hanging.
            stopVpn()

            // The 2 s stop timeout must fire before onDestroy can acquire the mutex.
            // After timeout: tearDownTun() force-called, state → Stopped.
            val stopped = awaitState(EngineState.Stopped::class.java, timeoutMs = 5_000L)
            assertNotNull("Service did not reach Stopped after timeout path", stopped)
        }

        val elapsedMs = System.currentTimeMillis() - startMs
        // The stop timeout is 2 s. Total elapsed must be well under 5 s
        // (the hang duration) — confirming the timeout fired, not the hang expiry.
        assertTrue(
            "Timeout path took ${elapsedMs}ms — expected < 5000ms (timeout must have fired)",
            elapsedMs < 5_000L,
        )

        // Timeout path must have recorded Stopping → Stopped.
        assertTrue(
            "Expected phase sequence Stopping → Stopped in trace: ${PhaseTrace.stateNames()}",
            PhaseTrace.containsSequence("Stopping", "Stopped"),
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
    }

    @Test(timeout = 15_000)
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
                awaitState(EngineState.Running::class.java, timeoutMs = 5_000L),
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
    @Test(timeout = 12_000)
    fun failedStartupCallsStop() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        FaultInjector.errorBeforeApplyConfig("injected-start-failure")

        runBlocking {
            // Start collecting before dispatching the service intent. Starting
            // and Error can be only milliseconds apart, and StateFlow correctly
            // conflates transient values for late subscribers.
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Error::class.java, timeoutMs = 4_000L)
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
    @Test(timeout = 12_000)
    fun jniGoroutinePanicCaughtByRecover() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        FaultInjector.panicOnJniGoroutine("injected-jni-panic")

        runBlocking {
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Error::class.java, timeoutMs = 4_000L)
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

        // Fire stop ~50 ms after start — bootCore will be inside the mutex hang.
        Thread.sleep(50)
        stopVpn()

        runBlocking {
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
    @Test(timeout = 20_000)
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
            val running = awaitState(EngineState.Running::class.java, timeoutMs = 12_000L)
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
            "Reconnect exceeded 5 seconds",
            System.currentTimeMillis() - startedAt < 5_000L,
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
    @Test(timeout = 12_000)
    fun errorStateCarriesMessage() {
        checkVpnPrepared()
        assumeFaultInjectAar()

        val injectedMsg = "error-message-visibility-check"
        FaultInjector.errorBeforeApplyConfig(injectedMsg)

        val errorState = runBlocking {
            val errorWait = async(start = CoroutineStart.UNDISPATCHED) {
                awaitState(EngineState.Error::class.java, timeoutMs = 8_000L)
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
}
