package com.yamax.veer.core_mihomo

import com.yamax.veer.core_logging.VeerLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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

    private val _startupStage = MutableStateFlow(StartupStage.IDLE)
    internal val startupStage: StateFlow<StartupStage> = _startupStage.asStateFlow()

    /** Live log stream backed by [VeerLog.flow]. Collected by the UI log panel. */
    val logs: SharedFlow<String> get() = VeerLog.flow

    // Settable from the debug source set (DebugLifecycleSetup). Null in release.
    @Volatile internal var stateObserver: ((EngineState) -> Unit)? = null
    @Volatile internal var startupStageObserver: ((StartupStage) -> Unit)? = null

    internal fun setState(next: EngineState) {
        stateObserver?.invoke(next)
        _state.value = next
        if (next !is EngineState.Starting) {
            setStartupStage(StartupStage.IDLE)
        }
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
}

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
    READY,
}
