package com.yamax.veer.ui.dns

import android.app.Application
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.core_profile.DnsOverrideValidator
import com.yamax.veer.core_profile.DnsValidationIssue
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.profile.ProfileRuntimeSwitchCoordinator
import com.yamax.veer.ui.uiText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

internal data class DnsSettingsUiState(
    val loading: Boolean = true,
    val saving: Boolean = false,
    val profileId: ProfileId? = null,
    val profileName: String = "",
    val isActiveProfile: Boolean = false,
    val runtimeState: EngineState = EngineState.Stopped,
    val policy: DnsOverridePolicy = DnsOverridePolicy(),
    val validationIssues: List<DnsValidationIssue> = emptyList(),
    val message: UiText? = null,
    val messageIsError: Boolean = false,
) {
    val canSave: Boolean
        get() = !loading && !saving && profileId != null && validationIssues.isEmpty()

    val reconnectRequired: Boolean
        get() = isActiveProfile && runtimeState is EngineState.Running
}

internal class DnsSettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val appContext = application.applicationContext
    private val _uiState = MutableStateFlow(DnsSettingsUiState())
    val uiState: StateFlow<DnsSettingsUiState> = _uiState.asStateFlow()

    private var targetId: ProfileId? = null
    private var pendingPolicy = DnsOverridePolicy()
    private var rollbackSnapshot: ProfileStore.DnsSettingsSnapshot? = null
    private var lastApplyError: String? = null

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
            ProfileManager.applyDnsSettings(appContext, profileId, pendingPolicy)
                .onFailure { lastApplyError = it.message }
                .isSuccess
        },
        requestStart = {
            ContextCompat.startForegroundService(
                appContext,
                VeerVpnService.startIntent(appContext),
            )
        },
        captureLastKnownGood = {
            val profileId = targetId
            if (profileId == null) {
                null
            } else {
                rollbackSnapshot = ProfileManager.captureDnsSettings(appContext, profileId)
                if (rollbackSnapshot == null) {
                    null
                } else {
                    ProfileManager.markActiveAsLastKnownGood(appContext)
                }
            }
        },
        restoreLastKnownGood = {
            rollbackSnapshot?.let {
                ProfileManager.restoreDnsSettings(appContext, it)
            }
        },
        recordStartupFailure = { attempted, previous, failure, rollbackSucceeded ->
            ProfileManager.recordActivationFailure(
                context = appContext,
                attemptedProfileId = attempted,
                previousProfileId = previous,
                stage = "DNS_${failure.stage.name}",
                message = failure.message,
                rollbackSucceeded = rollbackSucceeded,
            )
        },
        onPhase = { phase ->
            val message = uiText(when (phase) {
                ProfileRuntimeSwitchCoordinator.Phase.STOPPING ->
                    R.string.dns_phase_stopping
                ProfileRuntimeSwitchCoordinator.Phase.ACTIVATING ->
                    R.string.dns_phase_applying
                ProfileRuntimeSwitchCoordinator.Phase.STARTING ->
                    R.string.dns_phase_starting
                ProfileRuntimeSwitchCoordinator.Phase.ROLLING_BACK ->
                    R.string.dns_phase_rolling_back
            })
            _uiState.update { it.copy(message = message, messageIsError = false) }
        },
    )

    init {
        viewModelScope.launch {
            AppStateRepository.appState.collect { appState ->
                val id = targetId
                _uiState.update { current ->
                    current.copy(
                        isActiveProfile = id != null &&
                            appState.profile.activeProfileId == id,
                        runtimeState = appState.runtime.engineState,
                    )
                }
            }
        }
    }

    fun load(profileId: ProfileId? = null) {
        viewModelScope.launch {
            _uiState.update { it.copy(loading = true, message = null) }
            val settings = ProfileManager.loadDnsSettings(appContext, profileId)
            if (settings == null) {
                targetId = null
                _uiState.value = DnsSettingsUiState(
                    loading = false,
                    message = uiText(R.string.dns_no_profile_error),
                    messageIsError = true,
                    runtimeState = AppStateRepository.appState.value.runtime.engineState,
                )
                return@launch
            }
            targetId = settings.profileId
            val policy = settings.policy.normalized()
            _uiState.value = DnsSettingsUiState(
                loading = false,
                profileId = settings.profileId,
                profileName = settings.profileName,
                isActiveProfile = settings.isActive,
                runtimeState = AppStateRepository.appState.value.runtime.engineState,
                policy = policy,
                validationIssues = DnsOverrideValidator.validate(policy),
            )
        }
    }

    fun setMode(mode: DnsOverrideMode) {
        updatePolicy { current ->
            when {
                mode == DnsOverrideMode.INHERIT -> DnsOverridePolicy()
                current.mode == DnsOverrideMode.CUSTOM -> current
                else -> DnsOverridePolicy.recommendedCustom()
            }
        }
    }

    fun setIpv6(enabled: Boolean) = updatePolicy { it.copy(ipv6 = enabled) }

    fun setEnhancedMode(mode: DnsEnhancedMode) =
        updatePolicy { it.copy(enhancedMode = mode) }

    fun setDefaultNameservers(text: String) =
        updatePolicy { it.copy(defaultNameservers = text.toEndpointLines()) }

    fun setNameservers(text: String) =
        updatePolicy { it.copy(nameservers = text.toEndpointLines()) }

    fun setFallbackNameservers(text: String) =
        updatePolicy { it.copy(fallbackNameservers = text.toEndpointLines()) }

    fun save() {
        val snapshot = _uiState.value
        val profileId = snapshot.profileId ?: return
        if (!snapshot.canSave) return
        if (snapshot.isActiveProfile &&
            snapshot.runtimeState !is EngineState.Stopped &&
            snapshot.runtimeState !is EngineState.Running
        ) {
            _uiState.update {
                it.copy(
                    message = uiText(R.string.dns_runtime_transition_error),
                    messageIsError = true,
                )
            }
            return
        }

        pendingPolicy = snapshot.policy.normalized()
        rollbackSnapshot = null
        lastApplyError = null
        _uiState.update { it.copy(saving = true, message = null, messageIsError = false) }
        viewModelScope.launch {
            val result = if (!snapshot.isActiveProfile) {
                ProfileManager.applyDnsSettings(appContext, profileId, pendingPolicy).fold(
                    onSuccess = { ProfileRuntimeSwitchCoordinator.Result.Activated },
                    onFailure = {
                        lastApplyError = it.message
                        ProfileRuntimeSwitchCoordinator.Result.ActivationFailed
                    },
                )
            } else {
                runtimeSwitcher.switchTo(profileId)
            }
            val (message, isError) = result.toUserMessage(lastApplyError)
            val refreshed = ProfileManager.loadDnsSettings(appContext, profileId)
            val policy = refreshed?.policy?.normalized() ?: pendingPolicy
            _uiState.update {
                it.copy(
                    saving = false,
                    profileName = refreshed?.profileName ?: it.profileName,
                    isActiveProfile = refreshed?.isActive ?: it.isActiveProfile,
                    policy = policy,
                    validationIssues = DnsOverrideValidator.validate(policy),
                    message = message,
                    messageIsError = isError,
                )
            }
        }
    }

    fun dismissMessage() {
        _uiState.update { it.copy(message = null, messageIsError = false) }
    }

    private fun updatePolicy(transform: (DnsOverridePolicy) -> DnsOverridePolicy) {
        _uiState.update { current ->
            if (current.saving) return@update current
            val policy = transform(current.policy)
            current.copy(
                policy = policy,
                validationIssues = DnsOverrideValidator.validate(policy),
                message = null,
                messageIsError = false,
            )
        }
    }

    private fun ProfileRuntimeSwitchCoordinator.Result.toUserMessage(
        applyError: String?,
    ): Pair<UiText, Boolean> = when (this) {
        ProfileRuntimeSwitchCoordinator.Result.Activated ->
            uiText(R.string.dns_saved_next_connection) to false
        ProfileRuntimeSwitchCoordinator.Result.SwitchedAndRunning ->
            uiText(R.string.dns_applied_reconnected) to false
        ProfileRuntimeSwitchCoordinator.Result.Busy ->
            uiText(R.string.dns_save_busy) to true
        is ProfileRuntimeSwitchCoordinator.Result.RuntimeBusy ->
            uiText(R.string.dns_runtime_busy, state.label()) to true
        ProfileRuntimeSwitchCoordinator.Result.StopCommandFailed ->
            uiText(R.string.dns_stop_command_failed) to true
        ProfileRuntimeSwitchCoordinator.Result.StopTimedOut ->
            uiText(R.string.dns_stop_timeout) to true
        is ProfileRuntimeSwitchCoordinator.Result.StopFailed ->
            uiText(R.string.dns_stop_failed, message) to true
        ProfileRuntimeSwitchCoordinator.Result.ActivationFailed ->
            uiText(
                R.string.dns_apply_failed,
                applyError?.let(UiText::Verbatim) ?: uiText(R.string.dns_unknown_error),
            ) to true
        ProfileRuntimeSwitchCoordinator.Result.StartCommandFailed ->
            uiText(R.string.dns_start_command_failed) to true
        is ProfileRuntimeSwitchCoordinator.Result.StartTimedOut ->
            if (stoppedSafely) {
                uiText(R.string.dns_start_timeout_safe) to true
            } else {
                uiText(R.string.dns_start_timeout_unsafe) to true
            }
        is ProfileRuntimeSwitchCoordinator.Result.StartFailed ->
            uiText(R.string.dns_start_failed, message) to true
        is ProfileRuntimeSwitchCoordinator.Result.RolledBack ->
            uiText(R.string.dns_rolled_back) to true
        is ProfileRuntimeSwitchCoordinator.Result.RollbackFailed ->
            uiText(
                if (restartRequired) R.string.dns_rollback_failed_restart
                else R.string.dns_rollback_failed,
                rollbackMessage,
            ) to true
    }

    private fun EngineState.label(): UiText = when (this) {
        EngineState.Stopped -> uiText(R.string.dns_state_stopped)
        EngineState.Starting -> uiText(R.string.dns_state_starting)
        EngineState.Running -> uiText(R.string.dns_state_running)
        EngineState.Stopping -> uiText(R.string.dns_state_stopping)
        is EngineState.Error -> uiText(R.string.dns_engine_error_state)
    }
}

private fun String.toEndpointLines(): List<String> =
    lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
