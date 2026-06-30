package com.yamax.veer.app_state

import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Single source of truth for all observable application state.
 *
 * Aggregates [MihomoEngine.state], [ProfileManager.profiles], [ProfileManager.active],
 * [ProfileManager.importState], and connectivity callbacks into one
 * [StateFlow]<[AppState]>.
 *
 * ## Rules
 * - **ViewModels** observe [appState] exclusively; they do not reach into
 *   [MihomoEngine] or [ProfileManager] state flows directly.
 * - **Runtime code** ([com.yamax.veer.core_mihomo.VeerVpnService], [ProfileManager])
 *   continues to mutate its own internal StateFlows; it does NOT write directly
 *   to [_appState].
 * - **Cross-ViewModel communication** is not permitted; shared state travels
 *   through [appState] only.
 *
 * ## Lifetime
 * Initialized once in [com.yamax.veer.VeerApplication.onCreate] via [init] and
 * lives for the entire process lifetime. The internal [scope] never cancels.
 */
internal object AppStateRepository {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // -------------------------------------------------------------------------
    // Connectivity — only AppStateRepository writes here, from VeerVpnService
    // callbacks. The remaining slices are derived from existing subsystem flows.
    // -------------------------------------------------------------------------
    private val _connectivity = MutableStateFlow(ConnectivityState())

    private val _appState = MutableStateFlow(AppState())

    /** The live snapshot. Always has a current value. Never null. */
    val appState: StateFlow<AppState> = _appState.asStateFlow()

    // Tracks the wall-clock time the engine most recently entered Running.
    // Written only inside the combine lambda (single-writer, no lock needed).
    private var sessionStartedMs: Long? = null

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /**
     * Starts the aggregation pipeline. Must be called once from
     * [com.yamax.veer.VeerApplication.onCreate], after [ProfileManager.init].
     */
    fun init() {
        VeerLog.core("[AppStateRepository] init")

        // Stage 1: collapse the three ProfileManager flows into ProfileState.
        val profileFlow = combine(
            ProfileManager.profiles,
            ProfileManager.active,
            ProfileManager.importState,
        ) { profiles, active, importState ->
            ProfileState(
                profiles      = profiles,
                activeProfile = active,
                importState   = importState,
            )
        }

        // Stage 2: combine RuntimeState source, ProfileState, and connectivity.
        scope.launch {
            combine(
                MihomoEngine.state,
                profileFlow,
                _connectivity,
            ) { engineState, profile, connectivity ->
                AppState(
                    runtime      = buildRuntimeState(engineState),
                    profile      = profile,
                    connectivity = connectivity,
                    ui           = UiState(isReady = true),
                )
            }.collect { next ->
                val prev = _appState.value
                _appState.value = next
                logTransition(prev, next)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Connectivity update (additive; does not change runtime behavior)
    // -------------------------------------------------------------------------

    /**
     * Reports physical-network state from
     * [com.yamax.veer.core_mihomo.VeerVpnService]'s connectivity callbacks.
     *
     * Calling this does NOT affect the VPN session or any routing decision —
     * it only updates the observable [ConnectivityState] slice of [appState].
     */
    fun updateConnectivity(physicalNetworksAvailable: Int, hasInternet: Boolean) {
        _connectivity.value = ConnectivityState(
            physicalNetworksAvailable = physicalNetworksAvailable,
            hasInternet               = hasInternet,
        )
    }

    // -------------------------------------------------------------------------
    // Debug
    // -------------------------------------------------------------------------

    /**
     * Returns a human-readable dump of the current [AppState].
     * Safe to call from any thread. Intended for debug logging and crash reports.
     */
    fun dumpState(): String {
        val s  = _appState.value
        val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        return buildString {
            appendLine("=== AppState dump @ $ts ===")
            appendLine()
            appendLine("[runtime]")
            appendLine("  engineState      = ${s.runtime.engineState}")
            val sess = s.runtime.sessionStartedMs
            if (sess != null) {
                val durSec = (System.currentTimeMillis() - sess) / 1_000
                appendLine("  sessionStartedMs = $sess  (${durSec}s ago)")
            } else {
                appendLine("  sessionStartedMs = null")
            }
            appendLine()
            appendLine("[profile]")
            appendLine("  profiles.count   = ${s.profile.profiles.size}")
            appendLine("  activeProfileId  = ${s.profile.activeProfileId?.value ?: "none"}")
            s.profile.activeMetadata?.let { meta ->
                appendLine("  activeProfile    = \"${meta.displayName}\"  hash=${meta.configHashSha256.take(8)}…")
            }
            appendLine("  importState      = ${importStateLabel(s.profile.importState)}")
            appendLine()
            appendLine("[connectivity]")
            appendLine("  physicalNetworks = ${s.connectivity.physicalNetworksAvailable}")
            appendLine("  hasInternet      = ${s.connectivity.hasInternet}")
            appendLine()
            appendLine("[ui]")
            appendLine("  isReady          = ${s.ui.isReady}")
        }.trimEnd()
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private fun buildRuntimeState(engineState: EngineState): RuntimeState {
        when {
            engineState is EngineState.Running && sessionStartedMs == null ->
                sessionStartedMs = System.currentTimeMillis()
            engineState !is EngineState.Running ->
                sessionStartedMs = null
        }
        return RuntimeState(engineState = engineState, sessionStartedMs = sessionStartedMs)
    }

    private fun logTransition(prev: AppState, next: AppState) {
        if (prev.runtime.engineState != next.runtime.engineState) {
            VeerLog.core(
                "[AppStateRepository] engine: ${prev.runtime.engineState} → ${next.runtime.engineState}",
                VeerLog.Level.INFO,
            )
        }
        if (prev.profile.profiles.size != next.profile.profiles.size) {
            VeerLog.core(
                "[AppStateRepository] profiles: ${prev.profile.profiles.size} → ${next.profile.profiles.size}",
            )
        }
        if (prev.profile.activeProfileId != next.profile.activeProfileId) {
            val id = next.profile.activeProfileId?.value ?: "none"
            VeerLog.core("[AppStateRepository] activeProfile: → $id", VeerLog.Level.INFO)
        }
        if (prev.profile.importState::class != next.profile.importState::class) {
            VeerLog.core(
                "[AppStateRepository] importState: ${importStateLabel(prev.profile.importState)}" +
                    " → ${importStateLabel(next.profile.importState)}",
            )
        }
        if (prev.connectivity != next.connectivity) {
            VeerLog.core(
                "[AppStateRepository] connectivity: networks=${next.connectivity.physicalNetworksAvailable}" +
                    " internet=${next.connectivity.hasInternet}",
            )
        }
    }

    private fun importStateLabel(state: ImportState): String = when (state) {
        is ImportState.Idle    -> "Idle"
        is ImportState.Running -> "Running(${state.stage})"
        is ImportState.Success -> "Success(\"${state.profileName}\")"
        is ImportState.Failure -> "Failure(${state.errors.size} errors)"
    }
}
