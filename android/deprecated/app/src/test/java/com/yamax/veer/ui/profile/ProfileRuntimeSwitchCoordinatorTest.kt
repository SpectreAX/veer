package com.yamax.veer.ui.profile

import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_profile.ProfileId
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileRuntimeSwitchCoordinatorTest {

    private val target = ProfileId("target-profile")
    private val previous = ProfileId("previous-profile")

    @Test
    fun stoppedRuntimeActivatesWithoutRestarting() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Stopped)
        var stopCalls = 0
        var startCalls = 0
        val coordinator = coordinator(
            state = state,
            stop = { stopCalls++ },
            activate = { true },
            start = { startCalls++ },
        )

        assertEquals(
            ProfileRuntimeSwitchCoordinator.Result.Activated,
            coordinator.switchTo(target),
        )
        assertEquals(0, stopCalls)
        assertEquals(0, startCalls)
    }

    @Test
    fun runningRuntimeStopsActivatesAndRestartsInOrder() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        val events = mutableListOf<String>()
        val coordinator = coordinator(
            state = state,
            stop = {
                events += "stop"
                state.value = EngineState.Stopped
            },
            activate = {
                events += "activate"
                true
            },
            start = {
                events += "start"
                state.value = EngineState.Running
            },
        )

        assertEquals(
            ProfileRuntimeSwitchCoordinator.Result.SwitchedAndRunning,
            coordinator.switchTo(target),
        )
        assertEquals(listOf("stop", "activate", "start"), events)
    }

    @Test
    fun startCommandMayReturnBeforeAndroidPublishesStarting() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        val coordinator = coordinator(
            state = state,
            stop = { state.value = EngineState.Stopped },
            activate = { true },
            start = {
                launch {
                    delay(20)
                    state.value = EngineState.Starting
                    delay(20)
                    state.value = EngineState.Running
                }
            },
        )

        assertEquals(
            ProfileRuntimeSwitchCoordinator.Result.SwitchedAndRunning,
            coordinator.switchTo(target),
        )
    }

    @Test
    fun stopTimeoutNeverActivatesTarget() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        var activated = false
        val coordinator = coordinator(
            state = state,
            stop = { state.value = EngineState.Stopping },
            activate = {
                activated = true
                true
            },
            start = {},
            stopTimeoutMs = 25,
        )

        assertEquals(
            ProfileRuntimeSwitchCoordinator.Result.StopTimedOut,
            coordinator.switchTo(target),
        )
        assertFalse(activated)
    }

    @Test
    fun repeatedSwitchIsRejectedWhileFirstOperationOwnsMutex() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        var activationCount = 0
        val coordinator = coordinator(
            state = state,
            stop = { state.value = EngineState.Stopping },
            activate = {
                activationCount++
                true
            },
            start = { state.value = EngineState.Running },
            stopTimeoutMs = 1_000,
        )

        val first = async { coordinator.switchTo(target) }
        delay(25)
        val repeated = coordinator.switchTo(ProfileId("other-profile"))
        state.value = EngineState.Stopped

        assertEquals(ProfileRuntimeSwitchCoordinator.Result.Busy, repeated)
        assertEquals(
            ProfileRuntimeSwitchCoordinator.Result.SwitchedAndRunning,
            first.await(),
        )
        assertEquals(1, activationCount)
    }

    @Test
    fun stopErrorNeverActivatesTarget() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        var activated = false
        val coordinator = coordinator(
            state = state,
            stop = { state.value = EngineState.Error("native stop failed") },
            activate = {
                activated = true
                true
            },
            start = {},
        )

        val result = coordinator.switchTo(target)

        assertTrue(result is ProfileRuntimeSwitchCoordinator.Result.StopFailed)
        assertFalse(activated)
    }

    @Test
    fun failedTargetStartupRestoresLastKnownGoodAndReconnects() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        val events = mutableListOf<String>()
        var startCalls = 0
        var recordedRollback: Boolean? = null
        val coordinator = coordinator(
            state = state,
            stop = {
                events += "stop-old"
                state.value = EngineState.Stopped
            },
            activate = {
                events += "activate-target"
                true
            },
            start = {
                startCalls++
                if (startCalls == 1) {
                    events += "start-target"
                    state.value = EngineState.Error("injected startup failure")
                    launch {
                        delay(20)
                        state.value = EngineState.Stopping
                        delay(20)
                        state.value = EngineState.Stopped
                    }
                } else {
                    events += "start-rollback"
                    state.value = EngineState.Starting
                    state.value = EngineState.Running
                }
            },
            captureLastKnownGood = {
                events += "capture-lkg"
                previous
            },
            restoreLastKnownGood = {
                events += "restore-lkg"
                previous
            },
            recordStartupFailure = { _, _, _, rollbackSucceeded ->
                recordedRollback = rollbackSucceeded
            },
        )

        val result = coordinator.switchTo(target)

        assertTrue(result is ProfileRuntimeSwitchCoordinator.Result.RolledBack)
        assertEquals(
            listOf(
                "capture-lkg",
                "stop-old",
                "activate-target",
                "start-target",
                "restore-lkg",
                "start-rollback",
            ),
            events,
        )
        assertEquals(true, recordedRollback)
        assertEquals(EngineState.Running, state.value)
    }

    @Test
    fun activationFailureRestartsLastKnownGoodProfile() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        val events = mutableListOf<String>()
        val coordinator = coordinator(
            state = state,
            stop = {
                events += "stop"
                state.value = EngineState.Stopped
            },
            activate = {
                events += "activation-failed"
                false
            },
            start = {
                events += "restart-lkg"
                state.value = EngineState.Running
            },
            captureLastKnownGood = { previous },
            restoreLastKnownGood = {
                events += "restore-lkg"
                previous
            },
        )

        val result = coordinator.switchTo(target)

        assertTrue(result is ProfileRuntimeSwitchCoordinator.Result.RolledBack)
        assertEquals(
            listOf("stop", "activation-failed", "restore-lkg", "restart-lkg"),
            events,
        )
    }

    @Test
    fun failedStartupWithoutSnapshotStaysSafelyStopped() = runBlocking {
        val state = MutableStateFlow<EngineState>(EngineState.Running)
        val coordinator = coordinator(
            state = state,
            stop = { state.value = EngineState.Stopped },
            activate = { true },
            start = { state.value = EngineState.Error("bad config") },
            captureLastKnownGood = { null },
            restoreLastKnownGood = { null },
        )
        launch {
            delay(20)
            state.value = EngineState.Stopped
        }

        val result = coordinator.switchTo(target)

        assertTrue(result is ProfileRuntimeSwitchCoordinator.Result.RollbackFailed)
        assertEquals(EngineState.Stopped, state.value)
        assertFalse((result as ProfileRuntimeSwitchCoordinator.Result.RollbackFailed).restartRequired)
    }

    private fun coordinator(
        state: MutableStateFlow<EngineState>,
        stop: () -> Unit,
        activate: suspend (ProfileId) -> Boolean,
        start: () -> Unit,
        captureLastKnownGood: suspend () -> ProfileId? = { null },
        restoreLastKnownGood: suspend () -> ProfileId? = { null },
        recordStartupFailure:
            suspend (
                ProfileId,
                ProfileId?,
                ProfileRuntimeSwitchCoordinator.StartupFailure,
                Boolean,
            ) -> Unit = { _, _, _, _ -> },
        stopTimeoutMs: Long = 500,
    ) = ProfileRuntimeSwitchCoordinator(
        currentState = { state.value },
        stateChanges = state,
        requestStop = stop,
        activateProfile = activate,
        requestStart = start,
        captureLastKnownGood = captureLastKnownGood,
        restoreLastKnownGood = restoreLastKnownGood,
        recordStartupFailure = recordStartupFailure,
        stopTimeoutMs = stopTimeoutMs,
        startTimeoutMs = 500,
        rollbackStopTimeoutMs = 500,
    )
}
