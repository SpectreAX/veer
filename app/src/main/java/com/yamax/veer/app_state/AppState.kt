package com.yamax.veer.app_state

import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_profile.ActiveProfile
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata

// ─────────────────────────────────────────────────────────────────────────────
// Root

/**
 * Immutable snapshot of all observable application state.
 *
 * This is the single type collected by UI layers. Each slice is independently
 * updatable; a change in one slice does NOT require rebuilding the others.
 *
 * @see AppStateRepository for the live [kotlinx.coroutines.flow.StateFlow].
 */
internal data class AppState(
    val runtime:      RuntimeState      = RuntimeState(),
    val profile:      ProfileState      = ProfileState(),
    val connectivity: ConnectivityState = ConnectivityState(),
    val ui:           UiState           = UiState(),
)

// ─────────────────────────────────────────────────────────────────────────────
// RuntimeState

/**
 * Engine lifecycle and current session metadata.
 *
 * [sessionStartedMs] is set the moment [EngineState.Running] is first entered
 * in a given session, and cleared when the engine leaves Running. This lets
 * the UI display "connected for N minutes" without any timer logic.
 */
internal data class RuntimeState(
    val engineState:      EngineState = EngineState.Stopped,
    val sessionStartedMs: Long?       = null,
)

// ─────────────────────────────────────────────────────────────────────────────
// ProfileState

/**
 * All profile-related state: the persisted list, which profile is active, and
 * the current import pipeline phase.
 *
 * [activeMetadata] is a convenience that avoids list-scans in composables.
 */
internal data class ProfileState(
    val profiles:     List<ProfileMetadata> = emptyList(),
    val activeProfile: ActiveProfile?       = null,
    val importState:  ImportState           = ImportState.Idle,
) {
    val activeProfileId: ProfileId? get() = activeProfile?.profileId

    val activeMetadata: ProfileMetadata?
        get() = profiles.find { it.id == activeProfileId }
}

// ─────────────────────────────────────────────────────────────────────────────
// ConnectivityState

/**
 * Physical network availability as reported by [com.yamax.veer.core_mihomo.ConnectivityMonitor]
 * via [AppStateRepository.updateConnectivity].
 *
 * This slice is populated only while the VPN service is running; it resets to
 * defaults when the service tears down.
 */
internal data class ConnectivityState(
    val physicalNetworksAvailable: Int     = 0,
    val hasInternet:               Boolean = false,
)

// ─────────────────────────────────────────────────────────────────────────────
// ImportState (re-exported for uniform import path)

// com.yamax.veer.core_profile.ImportState is the canonical type; it is
// embedded as ProfileState.importState and accessible via appState.profile.importState.

// ─────────────────────────────────────────────────────────────────────────────
// UiState

/**
 * App-level UI hints that cut across all screens.
 *
 * Per-screen transient state (dialogs, text-field buffers, per-item spinners)
 * belongs in each ViewModel, not here. Only state that would be meaningful to
 * two or more independent screens belongs in UiState.
 *
 * [isReady] is false only during the brief startup window before
 * [AppStateRepository] has received its first combined emission.
 */
internal data class UiState(
    val isReady: Boolean = false,
)
