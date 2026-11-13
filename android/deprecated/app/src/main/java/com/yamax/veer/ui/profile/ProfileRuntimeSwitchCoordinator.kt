package com.yamax.veer.ui.profile

import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_profile.ProfileId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Serializes the runtime-sensitive part of profile activation.
 *
 * A profile must never be changed while the old Mihomo instance or TUN is still
 * alive. When switching from a running session, this coordinator waits for the
 * service to publish [EngineState.Stopped] before activating the new profile,
 * then waits for the replacement service to reach [EngineState.Running].
 */
internal class ProfileRuntimeSwitchCoordinator(
    private val currentState: () -> EngineState,
    private val stateChanges: Flow<EngineState>,
    private val requestStop: () -> Unit,
    private val activateProfile: suspend (ProfileId) -> Boolean,
    private val requestStart: () -> Unit,
    private val captureLastKnownGood: suspend () -> ProfileId? = { null },
    private val restoreLastKnownGood: suspend () -> ProfileId? = { null },
    private val recordStartupFailure:
        suspend (attempted: ProfileId, previous: ProfileId?, failure: StartupFailure, rollbackSucceeded: Boolean) -> Unit =
        { _, _, _, _ -> },
    private val onPhase: (Phase) -> Unit = {},
    private val stopTimeoutMs: Long = DEFAULT_STOP_TIMEOUT_MS,
    private val startTimeoutMs: Long = DEFAULT_START_TIMEOUT_MS,
    private val rollbackStopTimeoutMs: Long = DEFAULT_ROLLBACK_STOP_TIMEOUT_MS,
) {

    enum class Phase {
        STOPPING,
        ACTIVATING,
        STARTING,
        ROLLING_BACK,
    }

    enum class StartupFailureStage {
        ACTIVATION,
        START_COMMAND,
        START_RUNTIME,
        START_TIMEOUT,
    }

    data class StartupFailure(
        val stage: StartupFailureStage,
        val message: String,
    )

    sealed interface Result {
        data object Activated : Result
        data object SwitchedAndRunning : Result
        data object Busy : Result
        data class RuntimeBusy(val state: EngineState) : Result
        data object StopCommandFailed : Result
        data object StopTimedOut : Result
        data class StopFailed(val message: String) : Result
        data object ActivationFailed : Result
        data object StartCommandFailed : Result
        data class StartTimedOut(val stoppedSafely: Boolean) : Result
        data class StartFailed(val message: String) : Result
        data class RolledBack(
            val failedProfileId: ProfileId,
            val restoredProfileId: ProfileId,
            val failure: StartupFailure,
        ) : Result
        data class RollbackFailed(
            val failedProfileId: ProfileId,
            val previousProfileId: ProfileId?,
            val failure: StartupFailure,
            val rollbackMessage: String,
            val restartRequired: Boolean,
        ) : Result
    }

    private val operationMutex = Mutex()

    suspend fun switchTo(profileId: ProfileId): Result {
        if (!operationMutex.tryLock()) return Result.Busy
        try {
            val initialState = currentState()
            val restartAfterActivation = initialState is EngineState.Running
            val previousProfileId = if (restartAfterActivation) {
                runCatching { captureLastKnownGood() }.getOrNull()
            } else {
                null
            }

            when (initialState) {
                EngineState.Stopped -> Unit
                EngineState.Running -> {
                    onPhase(Phase.STOPPING)
                    if (runCatching(requestStop).isFailure) {
                        return Result.StopCommandFailed
                    }
                    when (val stopped = awaitStoppedOrError(stopTimeoutMs)) {
                        EngineState.Stopped -> Unit
                        is EngineState.Error -> return Result.StopFailed(stopped.message)
                        null -> return Result.StopTimedOut
                        else -> error("Unexpected stop terminal state: $stopped")
                    }
                }
                else -> return Result.RuntimeBusy(initialState)
            }

            // Re-check immediately before activation. This closes the gap where
            // another system event could start the runtime after the stop await.
            val beforeActivation = currentState()
            if (beforeActivation !is EngineState.Stopped) {
                return Result.RuntimeBusy(beforeActivation)
            }

            onPhase(Phase.ACTIVATING)
            if (!activateProfile(profileId)) {
                if (!restartAfterActivation) return Result.ActivationFailed
                return rollbackAfterFailure(
                    failedProfileId = profileId,
                    previousProfileId = previousProfileId,
                    failure = StartupFailure(
                        StartupFailureStage.ACTIVATION,
                        "Unable to activate the selected profile",
                    ),
                )
            }
            if (!restartAfterActivation) return Result.Activated

            onPhase(Phase.STARTING)
            if (runCatching(requestStart).isFailure) {
                return rollbackAfterFailure(
                    failedProfileId = profileId,
                    previousProfileId = previousProfileId,
                    failure = StartupFailure(
                        StartupFailureStage.START_COMMAND,
                        "VPN start command failed",
                    ),
                )
            }
            return when (val started = awaitStartOutcome(startTimeoutMs)) {
                EngineState.Running -> Result.SwitchedAndRunning
                EngineState.Stopped -> rollbackAfterFailure(
                    profileId,
                    previousProfileId,
                    StartupFailure(
                        StartupFailureStage.START_RUNTIME,
                        "VPN stopped before startup completed",
                    ),
                )
                is EngineState.Error -> rollbackAfterFailure(
                    profileId,
                    previousProfileId,
                    StartupFailure(StartupFailureStage.START_RUNTIME, started.message),
                )
                null -> {
                    val stoppedSafely = recoverTimedOutStart()
                    if (stoppedSafely) {
                        rollbackAfterFailure(
                            profileId,
                            previousProfileId,
                            StartupFailure(
                                StartupFailureStage.START_TIMEOUT,
                                "VPN startup timed out",
                            ),
                        )
                    } else {
                        val failure = StartupFailure(
                            StartupFailureStage.START_TIMEOUT,
                            "VPN startup and safe recovery timed out",
                        )
                        recordFailureSafely(
                            profileId,
                            previousProfileId,
                            failure,
                            rollbackSucceeded = false,
                        )
                        Result.StartTimedOut(stoppedSafely = false)
                    }
                }
                else -> error("Unexpected start terminal state: $started")
            }
        } finally {
            operationMutex.unlock()
        }
    }

    private suspend fun awaitStoppedOrError(timeoutMs: Long): EngineState? {
        val current = currentState()
        if (current is EngineState.Stopped || current is EngineState.Error) return current
        return withTimeoutOrNull(timeoutMs) {
            stateChanges.first { it is EngineState.Stopped || it is EngineState.Error }
        }
    }

    /**
     * Ignores the initial Stopped snapshot after startForegroundService(): the
     * command returns before Android necessarily calls onStartCommand(), so
     * treating that snapshot as a failed start would create a false failure.
     */
    private suspend fun awaitStartOutcome(timeoutMs: Long): EngineState? {
        val deadlineNanos = System.nanoTime() + timeoutMs * NANOS_PER_MILLISECOND
        val enteredStart = when (val current = currentState()) {
            EngineState.Running,
            EngineState.Starting,
            is EngineState.Error -> current
            else -> withTimeoutOrNull(remainingMillis(deadlineNanos)) {
                stateChanges.first {
                    it is EngineState.Starting ||
                        it is EngineState.Running ||
                        it is EngineState.Error
                }
            }
        }

        if (enteredStart !is EngineState.Starting) return enteredStart
        val remaining = remainingMillis(deadlineNanos)
        if (remaining <= 0L) return null
        return withTimeoutOrNull(remaining) {
            stateChanges.first {
                it is EngineState.Running ||
                    it is EngineState.Stopped ||
                    it is EngineState.Error
            }
        }
    }

    private suspend fun recoverTimedOutStart(): Boolean {
        return when (currentState()) {
            EngineState.Stopped -> true
            is EngineState.Error -> false
            else -> {
                if (runCatching(requestStop).isFailure) return false
                awaitStoppedOrError(stopTimeoutMs) is EngineState.Stopped
            }
        }
    }

    private suspend fun rollbackAfterFailure(
        failedProfileId: ProfileId,
        previousProfileId: ProfileId?,
        failure: StartupFailure,
    ): Result {
        onPhase(Phase.ROLLING_BACK)
        if (!awaitStoppedForRollback()) {
            recordFailureSafely(
                failedProfileId,
                previousProfileId,
                failure,
                rollbackSucceeded = false,
            )
            return Result.RollbackFailed(
                failedProfileId = failedProfileId,
                previousProfileId = previousProfileId,
                failure = failure,
                rollbackMessage = "The failed runtime did not stop safely",
                restartRequired = true,
            )
        }

        val restoredProfileId = runCatching { restoreLastKnownGood() }.getOrNull()
        if (restoredProfileId == null ||
            (previousProfileId != null && restoredProfileId != previousProfileId)
        ) {
            recordFailureSafely(
                failedProfileId,
                previousProfileId,
                failure,
                rollbackSucceeded = false,
            )
            return Result.RollbackFailed(
                failedProfileId = failedProfileId,
                previousProfileId = previousProfileId,
                failure = failure,
                rollbackMessage = "No matching last-known-good snapshot is available",
                restartRequired = false,
            )
        }

        if (runCatching(requestStart).isFailure) {
            recordFailureSafely(
                failedProfileId,
                previousProfileId,
                failure,
                rollbackSucceeded = false,
            )
            return Result.RollbackFailed(
                failedProfileId = failedProfileId,
                previousProfileId = previousProfileId,
                failure = failure,
                rollbackMessage = "The restored profile could not be started",
                restartRequired = false,
            )
        }

        val rollbackOutcome = awaitStartOutcome(startTimeoutMs)
        if (rollbackOutcome is EngineState.Running) {
            recordFailureSafely(
                failedProfileId,
                previousProfileId,
                failure,
                rollbackSucceeded = true,
            )
            return Result.RolledBack(
                failedProfileId = failedProfileId,
                restoredProfileId = restoredProfileId,
                failure = failure,
            )
        }

        val stoppedSafely = when (rollbackOutcome) {
            EngineState.Stopped -> true
            else -> recoverTimedOutStart()
        }
        recordFailureSafely(
            failedProfileId,
            previousProfileId,
            failure,
            rollbackSucceeded = false,
        )
        return Result.RollbackFailed(
            failedProfileId = failedProfileId,
            previousProfileId = previousProfileId,
            failure = failure,
            rollbackMessage = when (rollbackOutcome) {
                is EngineState.Error -> "Restored profile failed: ${rollbackOutcome.message}"
                null -> "Restored profile startup timed out"
                else -> "Restored profile stopped before startup completed"
            },
            restartRequired = !stoppedSafely,
        )
    }

    private suspend fun awaitStoppedForRollback(): Boolean {
        if (currentState() is EngineState.Stopped) return true
        return withTimeoutOrNull(rollbackStopTimeoutMs) {
            stateChanges.first { it is EngineState.Stopped }
            true
        } == true
    }

    private suspend fun recordFailureSafely(
        failedProfileId: ProfileId,
        previousProfileId: ProfileId?,
        failure: StartupFailure,
        rollbackSucceeded: Boolean,
    ) {
        runCatching {
            recordStartupFailure(
                failedProfileId,
                previousProfileId,
                failure,
                rollbackSucceeded,
            )
        }
    }

    private fun remainingMillis(deadlineNanos: Long): Long =
        ((deadlineNanos - System.nanoTime()) / NANOS_PER_MILLISECOND).coerceAtLeast(1L)

    private companion object {
        // Explicit shutdown normally completes in ~3.5 s on the Android 16
        // emulator because Android delays onDestroy after stopSelf().
        const val DEFAULT_STOP_TIMEOUT_MS = 12_000L
        const val DEFAULT_START_TIMEOUT_MS = 20_000L
        const val DEFAULT_ROLLBACK_STOP_TIMEOUT_MS = 20_000L
        const val NANOS_PER_MILLISECOND = 1_000_000L
    }
}
