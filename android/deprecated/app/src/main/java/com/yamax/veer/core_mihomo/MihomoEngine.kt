package com.yamax.veer.core_mihomo

import com.yamax.veer.core_logging.VeerLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicLong

/**
 * Process-wide observable state for the Mihomo core.
 *
 * UI / AI layers READ state and logs from here but must not mutate either.
 * The `internal` mutators are reachable only from this module's other Kotlin files
 * (VeerVpnService, VeerLogger, ConnectivityMonitor).
 *
 * Log output is backed by [VeerLog]: every entry written via [publishLifecycleLog]
 * or [publishCoreLog] is also written to Logcat (tag "Veer"), the on-disk rolling
 * log, and the in-memory ring buffer.
 */
object MihomoEngine {

    private val _state = MutableStateFlow<EngineState>(EngineState.Stopped)
    val state: StateFlow<EngineState> = _state.asStateFlow()

    private val _status = MutableStateFlow(
        EngineStatus(
            state = EngineState.Stopped,
            timestampMs = System.currentTimeMillis(),
            operationId = "bootstrap-0",
            message = "Mihomo is stopped",
            machineCode = "CORE_STOPPED",
            rootCause = null,
            recoverability = EngineRecoverability.NOT_APPLICABLE,
        ),
    )
    internal val status: StateFlow<EngineStatus> = _status.asStateFlow()

    private val _startupStage = MutableStateFlow(StartupStage.IDLE)
    internal val startupStage: StateFlow<StartupStage> = _startupStage.asStateFlow()

    /** Live log stream backed by [VeerLog.flow]. Collected by the UI log panel. */
    val logs: SharedFlow<String> get() = VeerLog.flow

    // Settable from the debug source set (DebugLifecycleSetup). Null in release.
    @Volatile internal var stateObserver: ((EngineState) -> Unit)? = null
    @Volatile internal var startupStageObserver: ((StartupStage) -> Unit)? = null
    private val operationSequence = AtomicLong()
    @Volatile private var activeOperationId: String = "bootstrap-0"

    internal fun beginOperation(kind: String): String {
        val normalized = kind.lowercase().replace(Regex("[^a-z0-9_]+"), "_")
        return "$normalized-${System.currentTimeMillis()}-${operationSequence.incrementAndGet()}"
            .also { activeOperationId = it }
    }

    internal fun setState(
        next: EngineState,
        message: String = defaultMessage(next),
        machineCode: String = defaultMachineCode(next),
        rootCause: String? = (next as? EngineState.Error)?.message,
        recoverability: EngineRecoverability = defaultRecoverability(next),
        operationId: String = activeOperationId,
        timestampMs: Long = System.currentTimeMillis(),
    ) {
        stateObserver?.invoke(next)
        _state.value = next
        _status.value = EngineStatus(
            state = next,
            timestampMs = timestampMs,
            operationId = operationId,
            message = message,
            machineCode = machineCode,
            rootCause = rootCause,
            recoverability = recoverability,
        )
        if (next !is EngineState.Starting) {
            setStartupStage(StartupStage.IDLE)
        }
    }

    /** Applies the core process's authoritative status without inventing metadata. */
    internal fun syncStatus(remote: EngineStatus) {
        activeOperationId = remote.operationId
        if (_state.value != remote.state) {
            stateObserver?.invoke(remote.state)
        }
        _state.value = remote.state
        _status.value = remote
    }

    internal fun setStartupStage(next: StartupStage) {
        startupStageObserver?.invoke(next)
        _startupStage.value = next
    }

    /**
     * Backward-compatible shim: infers a [VeerLog.Cat] from common `[tag]` prefixes
     * and delegates to [VeerLog]. New callsites should use the typed API directly
     * (e.g. [VeerLog.vpn], [VeerLog.profile]) rather than this method.
     */
    internal fun publishLifecycleLog(line: String) {
        VeerLog.log(inferCat(line), line)
    }

    internal fun publishCoreLog(line: String) {
        VeerLog.go(line)
    }

    private fun inferCat(line: String): VeerLog.Cat = when {
        line.startsWith("[connectivity") -> VeerLog.Cat.CONNECTIVITY
        line.startsWith("[watchdog")     -> VeerLog.Cat.WATCHDOG
        line.startsWith("[parser")       -> VeerLog.Cat.PARSER
        line.startsWith("[profile")      -> VeerLog.Cat.PROFILE
        line.startsWith("[generator")    -> VeerLog.Cat.PARSER
        line.startsWith("[bootCore")     -> VeerLog.Cat.VPN
        line.startsWith("[tearDownCore") -> VeerLog.Cat.VPN
        line.startsWith("[onDestroy")    -> VeerLog.Cat.VPN
        line.startsWith("[stop]")        -> VeerLog.Cat.VPN
        else                             -> VeerLog.Cat.CORE
    }

    private fun defaultMessage(state: EngineState): String = when (state) {
        EngineState.Stopped -> "Mihomo is stopped"
        EngineState.Starting -> "Mihomo is starting"
        EngineState.Running -> "Mihomo is ready"
        EngineState.Stopping -> "Mihomo is stopping"
        is EngineState.Error -> state.message
    }

    private fun defaultMachineCode(state: EngineState): String = when (state) {
        EngineState.Stopped -> "CORE_STOPPED"
        EngineState.Starting -> "CORE_STARTING"
        EngineState.Running -> "CORE_RUNNING"
        EngineState.Stopping -> "CORE_STOPPING"
        is EngineState.Error -> "CORE_ERROR"
    }

    private fun defaultRecoverability(state: EngineState): EngineRecoverability = when (state) {
        is EngineState.Error -> EngineRecoverability.RESTART_CORE
        else -> EngineRecoverability.NOT_APPLICABLE
    }
}

internal enum class EngineRecoverability {
    NOT_APPLICABLE,
    RETRY,
    RESTART_CORE,
    RESTART_APP,
}

internal data class EngineStatus(
    val state: EngineState,
    val timestampMs: Long,
    val operationId: String,
    val message: String,
    val machineCode: String,
    val rootCause: String?,
    val recoverability: EngineRecoverability,
)

sealed interface EngineState {
    data object Stopped  : EngineState
    data object Starting : EngineState
    data object Running  : EngineState
    data object Stopping : EngineState
    data class Error(val message: String) : EngineState
}

/**
 * Real startup boundaries published by [VeerVpnService].
 *
 * These values describe completed/active work, not elapsed time. Keeping them
 * beside [EngineState] makes the service the sole lifecycle writer while the UI
 * remains a passive observer.
 */
internal enum class StartupStage {
    IDLE,
    PREPARING_CONFIG,
    ENSURING_GEO_DATA,
    VALIDATING_CONFIG,
    ESTABLISHING_TUNNEL,
    STARTING_RUNTIME,
    VERIFYING_RUNTIME,
    READY,
}
