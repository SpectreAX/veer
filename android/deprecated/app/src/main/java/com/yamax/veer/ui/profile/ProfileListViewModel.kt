package com.yamax.veer.ui.profile

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import androidx.annotation.StringRes
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.R
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.core_profile.SubscriptionRefreshHistory
import com.yamax.veer.core_profile.SubscriptionRefreshRecord
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.parser.ProfileImportPolicy
import com.yamax.veer.core_profile.internal.parser.message
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.uiText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

internal class ProfileListViewModel(application: Application) : AndroidViewModel(application) {

    data class UiState(
        val profiles: List<ProfileMetadata> = emptyList(),
        val activeProfileId: ProfileId? = null,
        val importState: ImportState = ImportState.Idle,
        val refreshingIds: Set<String> = emptySet(),
        val isRefreshingAll: Boolean = false,
        val errorBanner: UiText? = null,
        val editDialog: EditDialog? = null,
        val deleteTarget: ProfileId? = null,
        val runtimeStopped: Boolean = true,
        val profileSwitchAllowed: Boolean = true,
        val switchingProfileId: ProfileId? = null,
        val switchStatus: UiText? = null,
        val refreshHistory: List<SubscriptionRefreshRecord> = emptyList(),
    )

    data class EditDialog(
        val profileId: ProfileId,
        val editedName: String,
    )

    private data class ExtraState(
        val refreshingIds: Set<String> = emptySet(),
        val isRefreshingAll: Boolean = false,
        val errorBanner: UiText? = null,
        val editDialog: EditDialog? = null,
        val deleteTarget: ProfileId? = null,
        val switchingProfileId: ProfileId? = null,
        val switchStatus: UiText? = null,
    )

    private val _extra = MutableStateFlow(ExtraState())

    val uiState: StateFlow<UiState> = combine(
        AppStateRepository.appState,
        _extra,
        SubscriptionRefreshHistory.records,
    ) { appState, extra, refreshHistory ->
        val profile = appState.profile
        UiState(
            profiles        = profile.profiles.sortedByDescending { it.lastUpdatedMs },
            activeProfileId = profile.activeProfileId,
            importState     = profile.importState,
            refreshingIds   = extra.refreshingIds,
            isRefreshingAll = extra.isRefreshingAll,
            errorBanner     = extra.errorBanner,
            editDialog      = extra.editDialog,
            deleteTarget    = extra.deleteTarget,
            runtimeStopped  = appState.runtime.engineState is EngineState.Stopped,
            profileSwitchAllowed =
                appState.runtime.engineState is EngineState.Stopped ||
                    appState.runtime.engineState is EngineState.Running,
            switchingProfileId = extra.switchingProfileId,
            switchStatus       = extra.switchStatus,
            refreshHistory     = refreshHistory.take(5),
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState())

    private val appContext = application.applicationContext
    private val runtimeSwitcher = ProfileRuntimeSwitchCoordinator(
        currentState = { AppStateRepository.appState.value.runtime.engineState },
        stateChanges = AppStateRepository.appState
            .map { it.runtime.engineState }
            .distinctUntilChanged(),
        requestStop = {
            ContextCompat.startForegroundService(
                appContext,
                VeerVpnService.prepareProfileSwitchIntent(appContext),
            )
        },
        activateProfile = { profileId ->
            ProfileManager.activate(appContext, profileId)
        },
        requestStart = {
            ContextCompat.startForegroundService(
                appContext,
                VeerVpnService.startIntent(appContext),
            )
        },
        captureLastKnownGood = {
            ProfileManager.markActiveAsLastKnownGood(appContext)
        },
        restoreLastKnownGood = {
            ProfileManager.restoreLastKnownGood(appContext)
        },
        recordStartupFailure = { attempted, previous, failure, rollbackSucceeded ->
            ProfileManager.recordActivationFailure(
                context = appContext,
                attemptedProfileId = attempted,
                previousProfileId = previous,
                stage = failure.stage.name,
                message = failure.message,
                rollbackSucceeded = rollbackSucceeded,
            )
        },
        onPhase = { phase ->
            val message = uiText(when (phase) {
                ProfileRuntimeSwitchCoordinator.Phase.STOPPING ->
                    R.string.profile_phase_stopping
                ProfileRuntimeSwitchCoordinator.Phase.ACTIVATING ->
                    R.string.profile_phase_activating
                ProfileRuntimeSwitchCoordinator.Phase.STARTING ->
                    R.string.profile_phase_starting
                ProfileRuntimeSwitchCoordinator.Phase.ROLLING_BACK ->
                    R.string.profile_phase_rolling_back
            })
            _extra.update { it.copy(switchStatus = message) }
        },
    )

    // -------------------------------------------------------------------------
    // Import
    // -------------------------------------------------------------------------

    fun importUrl(url: String) {
        val trimmed = url.trim()
        if (trimmed.isBlank()) return
        viewModelScope.launch {
            val result = ProfileManager.import(getApplication(), ProfileInput.SubscriptionUrl(trimmed))
            handleImportResult(
                result,
                R.string.profile_subscription_import_failed,
                "subscription import",
            )
        }
    }

    fun importYaml(yaml: String) {
        val trimmed = yaml.trim()
        if (trimmed.isBlank()) return
        viewModelScope.launch {
            val result = ProfileManager.import(
                getApplication(),
                ProfileInput.YamlBytes(trimmed.toByteArray(Charsets.UTF_8), "pasted.yaml"),
            )
            handleImportResult(result, R.string.profile_yaml_import_failed, "YAML import")
        }
    }

    fun importDocument(uri: Uri) {
        viewModelScope.launch {
            val loaded = withContext(Dispatchers.IO) {
                runCatching {
                    val resolver = getApplication<Application>().contentResolver
                    val displayName = resolver.query(
                        uri,
                        arrayOf(OpenableColumns.DISPLAY_NAME),
                        null,
                        null,
                        null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: "profile.yaml"
                    val bytes = resolver.openInputStream(uri)?.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        var total = 0
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= ProfileImportPolicy.MAX_PROFILE_BYTES) {
                                "Profile exceeds the 10 MiB limit"
                            }
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    } ?: error("Unable to open selected file")
                    displayName to bytes
                }
            }
            loaded.onFailure { error ->
                _extra.update {
                    it.copy(
                        errorBanner = uiText(
                            R.string.profile_file_import_failed,
                            error.message.orEmpty(),
                        ),
                    )
                }
            }.onSuccess { (displayName, bytes) ->
                val result = ProfileManager.import(
                    getApplication(),
                    ProfileInput.YamlBytes(bytes, displayName),
                )
                handleImportResult(result, R.string.profile_file_import_failed, "file import")
            }
        }
    }

    /**
     * The first valid profile is immediately activated. Importing additional
     * profiles remains non-disruptive: switching an existing active profile
     * still requires an explicit user action.
     */
    private fun handleImportResult(
        result: ImportResult,
        @StringRes failureResource: Int,
        operationLogName: String,
    ) {
        when (result) {
            is ImportResult.Failure -> {
                val msg = result.errors.joinToString("; ") { it.message() }
                VeerLog.profile("$operationLogName failed: $msg", VeerLog.Level.ERROR)
                _extra.update {
                    it.copy(errorBanner = uiText(failureResource, msg))
                }
            }
            is ImportResult.Success -> {
                val activeId = AppStateRepository.appState.value.profile.activeProfileId
                if (activeId == null) {
                    activate(result.profile.id)
                } else {
                    _extra.update {
                        it.copy(
                            switchStatus = uiText(R.string.profile_imported_active_unchanged),
                        )
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Profile actions
    // -------------------------------------------------------------------------

    fun activate(profileId: ProfileId) {
        if (uiState.value.activeProfileId == profileId) return
        if (_extra.value.switchingProfileId != null) return
        // Claim the UI operation synchronously on the main thread before
        // launching. Repeated taps delivered in the same frame therefore see a
        // non-null switchingProfileId and cannot enqueue parallel coroutines.
        _extra.update {
            it.copy(
                switchingProfileId = profileId,
                switchStatus = uiText(R.string.profile_preparing_activation),
                errorBanner = null,
            )
        }
        viewModelScope.launch {
            val result = runtimeSwitcher.switchTo(profileId)
            val error: UiText? = when (result) {
                ProfileRuntimeSwitchCoordinator.Result.Activated -> null
                ProfileRuntimeSwitchCoordinator.Result.SwitchedAndRunning -> null
                ProfileRuntimeSwitchCoordinator.Result.Busy ->
                    uiText(R.string.profile_switch_busy)
                is ProfileRuntimeSwitchCoordinator.Result.RuntimeBusy ->
                    uiText(R.string.profile_runtime_busy, result.state.labelForSwitch())
                ProfileRuntimeSwitchCoordinator.Result.StopCommandFailed ->
                    uiText(R.string.profile_stop_command_failed)
                ProfileRuntimeSwitchCoordinator.Result.StopTimedOut ->
                    uiText(R.string.profile_stop_timed_out)
                is ProfileRuntimeSwitchCoordinator.Result.StopFailed ->
                    uiText(R.string.profile_stop_failed, result.message)
                ProfileRuntimeSwitchCoordinator.Result.ActivationFailed ->
                    uiText(R.string.profile_activation_failed)
                ProfileRuntimeSwitchCoordinator.Result.StartCommandFailed ->
                    uiText(R.string.profile_start_command_failed)
                is ProfileRuntimeSwitchCoordinator.Result.StartTimedOut ->
                    if (result.stoppedSafely) {
                        uiText(R.string.profile_start_timeout_safe)
                    } else {
                        uiText(R.string.profile_start_timeout_unsafe)
                    }
                is ProfileRuntimeSwitchCoordinator.Result.StartFailed ->
                    uiText(R.string.profile_start_failed, result.message)
                is ProfileRuntimeSwitchCoordinator.Result.RolledBack ->
                    uiText(
                        R.string.profile_rolled_back,
                        result.failure.stage.localizedLabel(),
                    )
                is ProfileRuntimeSwitchCoordinator.Result.RollbackFailed ->
                    uiText(
                        if (result.restartRequired) R.string.profile_rollback_failed_restart
                        else R.string.profile_rollback_failed,
                        result.failure.stage.localizedLabel(),
                        result.rollbackMessage,
                    )
            }
            val success: UiText? = when (result) {
                ProfileRuntimeSwitchCoordinator.Result.Activated ->
                    uiText(R.string.profile_activated)
                ProfileRuntimeSwitchCoordinator.Result.SwitchedAndRunning ->
                    uiText(R.string.profile_switched_running)
                else -> null
            }
            _extra.update {
                it.copy(
                    switchingProfileId = null,
                    switchStatus = success,
                    errorBanner = error,
                )
            }
        }
    }

    fun requestDelete(profileId: ProfileId) {
        _extra.update { it.copy(deleteTarget = profileId) }
    }

    fun dismissDelete() {
        _extra.update { it.copy(deleteTarget = null) }
    }

    fun confirmDelete() {
        val id = _extra.value.deleteTarget ?: return
        if (!uiState.value.runtimeStopped && uiState.value.activeProfileId == id) {
            _extra.update {
                it.copy(
                    deleteTarget = null,
                    errorBanner = uiText(R.string.profile_delete_active_requires_stop),
                )
            }
            return
        }
        _extra.update { it.copy(deleteTarget = null) }
        viewModelScope.launch {
            ProfileManager.delete(getApplication(), id)
        }
    }

    fun refresh(profileId: ProfileId) {
        if (uiState.value.activeProfileId == profileId &&
            !ensureRuntimeStopped(uiText(R.string.profile_refresh_active_requires_stop))) return
        viewModelScope.launch {
            _extra.update { it.copy(refreshingIds = it.refreshingIds + profileId.value) }
            val result = ProfileManager.refresh(getApplication(), profileId)
            _extra.update { it.copy(refreshingIds = it.refreshingIds - profileId.value) }
            if (result is ImportResult.Failure) {
                val msg = result.errors.joinToString("; ") { it.message() }
                _extra.update {
                    it.copy(errorBanner = uiText(R.string.profile_refresh_error, msg))
                }
            }
        }
    }

    fun refreshAll() {
        viewModelScope.launch {
            val activeId = uiState.value.activeProfileId
            val runtimeStopped = uiState.value.runtimeStopped
            val urlProfiles = ProfileManager.profiles.value
                .filter { it.source is ProfileSource.SubscriptionUrl }
                .filter { runtimeStopped || it.id != activeId }
            if (urlProfiles.isEmpty()) return@launch
            _extra.update { it.copy(isRefreshingAll = true) }
            for (meta in urlProfiles) {
                _extra.update { it.copy(refreshingIds = it.refreshingIds + meta.id.value) }
                val result = ProfileManager.refresh(getApplication(), meta.id)
                _extra.update { it.copy(refreshingIds = it.refreshingIds - meta.id.value) }
                if (result is ImportResult.Failure) {
                    val msg = result.errors.joinToString("; ") { it.message() }
                    _extra.update {
                        it.copy(
                            errorBanner = uiText(
                                R.string.profile_refresh_named_error,
                                meta.displayName,
                                msg,
                            ),
                        )
                    }
                }
            }
            _extra.update { it.copy(isRefreshingAll = false) }
        }
    }

    // -------------------------------------------------------------------------
    // Rename dialog
    // -------------------------------------------------------------------------

    fun startEdit(profileId: ProfileId) {
        val name = ProfileManager.profiles.value.find { it.id == profileId }?.displayName ?: ""
        _extra.update { it.copy(editDialog = EditDialog(profileId, name)) }
    }

    fun updateEditName(name: String) {
        _extra.update { s -> s.copy(editDialog = s.editDialog?.copy(editedName = name)) }
    }

    fun submitEdit() {
        val dialog = _extra.value.editDialog ?: return
        _extra.update { it.copy(editDialog = null) }
        val name = dialog.editedName.trim()
        if (name.isBlank()) return
        viewModelScope.launch {
            ProfileManager.rename(getApplication(), dialog.profileId, name)
        }
    }

    fun dismissEdit() {
        _extra.update { it.copy(editDialog = null) }
    }

    // -------------------------------------------------------------------------
    // Banners / state
    // -------------------------------------------------------------------------

    fun dismissErrorBanner() {
        _extra.update { it.copy(errorBanner = null) }
    }

    fun clearImportState() {
        ProfileManager.clearImportState()
    }

    private fun ensureRuntimeStopped(message: UiText): Boolean {
        if (uiState.value.runtimeStopped) return true
        _extra.update { it.copy(errorBanner = message) }
        return false
    }

    private fun EngineState.labelForSwitch(): UiText = when (this) {
        EngineState.Stopped -> uiText(R.string.engine_stopped)
        EngineState.Starting -> uiText(R.string.engine_starting)
        EngineState.Running -> uiText(R.string.engine_running)
        EngineState.Stopping -> uiText(R.string.engine_stopping)
        is EngineState.Error -> uiText(R.string.profile_engine_error_state)
    }

    private fun ProfileRuntimeSwitchCoordinator.StartupFailureStage.localizedLabel(): UiText =
        uiText(when (this) {
            ProfileRuntimeSwitchCoordinator.StartupFailureStage.ACTIVATION ->
                R.string.profile_failure_stage_activation
            ProfileRuntimeSwitchCoordinator.StartupFailureStage.START_COMMAND ->
                R.string.profile_failure_stage_start_command
            ProfileRuntimeSwitchCoordinator.StartupFailureStage.START_RUNTIME ->
                R.string.profile_failure_stage_start_runtime
            ProfileRuntimeSwitchCoordinator.StartupFailureStage.START_TIMEOUT ->
                R.string.profile_failure_stage_start_timeout
        })
}
