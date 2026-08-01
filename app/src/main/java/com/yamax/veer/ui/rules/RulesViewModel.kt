package com.yamax.veer.ui.rules

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.data.AiRulesSnapshot
import com.yamax.veer.data.ConfigManager
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.uiText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class RulesUiState(
    val profileName: String? = null,
    val profileId: String? = null,
    val rules: List<ManagedAiRule> = emptyList(),
    val availablePolicies: List<String> = emptyList(),
    val unavailablePolicies: Set<String> = emptySet(),
    val engineRunning: Boolean = false,
    val loading: Boolean = true,
    val busyRuleId: String? = null,
    val message: UiText? = null,
)

internal class RulesViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    private val mihomo = MihomoRepository.get()
    private val _uiState = MutableStateFlow(RulesUiState())
    val uiState: StateFlow<RulesUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            AppStateRepository.appState
                .map { state ->
                    state.profile.activeProfileId?.value to
                        (state.runtime.engineState is EngineState.Running)
                }
                .distinctUntilChanged()
                .collect { refresh() }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            val startingState = AppStateRepository.appState.value
            val running = startingState.runtime.engineState is EngineState.Running
            _uiState.update { it.copy(loading = true, engineRunning = running) }
            val snapshot = withContext(Dispatchers.IO) {
                ConfigManager.aiRulesSnapshot(context)
            }
            // ProfileManager and AppStateRepository initialize asynchronously at
            // process start. Re-read after disk I/O so an early refresh cannot
            // publish a stale "no profile" state over the initialized profile.
            val appState = AppStateRepository.appState.value
            val currentlyRunning = appState.runtime.engineState is EngineState.Running
            val unavailable = if (currentlyRunning) {
                runCatching {
                    mihomo.routingSnapshot().let { runtime ->
                        snapshot.rules.asSequence()
                            .map(ManagedAiRule::policy)
                            .filter(runtime::isKnownUnavailable)
                            .toSet()
                    }
                }.getOrDefault(emptySet())
            } else {
                emptySet()
            }
            _uiState.update {
                it.copy(
                    profileName = appState.profile.activeMetadata?.displayName
                        ?: appState.profile.activeProfileId?.value,
                    profileId = appState.profile.activeProfileId?.value,
                    rules = snapshot.rules,
                    availablePolicies = snapshot.availablePolicies,
                    unavailablePolicies = unavailable,
                    engineRunning = currentlyRunning,
                    loading = false,
                )
            }
        }
    }

    fun setEnabled(ruleId: String, enabled: Boolean) {
        mutate(
            ruleId,
            uiText(if (enabled) R.string.rules_enabled else R.string.rules_disabled),
        ) {
            ConfigManager.setAiRuleEnabled(context, ruleId, enabled)
        }
    }

    fun delete(ruleId: String) {
        mutate(ruleId, uiText(R.string.rules_deleted)) {
            ConfigManager.deleteAiRule(context, ruleId)
        }
    }

    fun rebind(ruleId: String, policy: String) {
        if (policy !in _uiState.value.availablePolicies) {
            _uiState.update { it.copy(message = uiText(R.string.rules_policy_missing)) }
            return
        }
        mutate(ruleId, uiText(R.string.rules_rebound, policy)) {
            ConfigManager.rebindAiRule(context, ruleId, policy)
        }
    }

    fun reapply() {
        viewModelScope.launch {
            _uiState.update { it.copy(loading = true, message = null) }
            val message = applyRules()
            refreshAfterMutation(message)
        }
    }

    fun clearMessage() {
        _uiState.update { it.copy(message = null) }
    }

    private fun mutate(ruleId: String, successMessage: UiText, change: () -> Boolean) {
        if (_uiState.value.busyRuleId != null) return
        viewModelScope.launch {
            _uiState.update { it.copy(busyRuleId = ruleId, message = null) }
            val changed = withContext(Dispatchers.IO) { change() }
            val message = if (changed) {
                uiText(R.string.rules_mutation_result, successMessage, applyRules())
            } else {
                uiText(R.string.rules_no_change)
            }
            refreshAfterMutation(message)
        }
    }

    private suspend fun applyRules(): UiText {
        val config = withContext(Dispatchers.IO) {
            ConfigManager.materializeBaseConfig(context)
        }
        val running = AppStateRepository.appState.value.runtime.engineState is EngineState.Running
        if (!running) return uiText(R.string.rules_saved_next_connection)
        val result = mihomo.reloadRules(config)
        return if (result.success) {
            uiText(R.string.rules_synced_current)
        } else {
            uiText(R.string.rules_runtime_load_failed, result.message)
        }
    }

    private suspend fun refreshAfterMutation(message: UiText) {
        val appState = AppStateRepository.appState.value
        val snapshot: AiRulesSnapshot = withContext(Dispatchers.IO) {
            ConfigManager.aiRulesSnapshot(context)
        }
        val running = appState.runtime.engineState is EngineState.Running
        val unavailable = if (running) {
            runCatching {
                mihomo.routingSnapshot().let { runtime ->
                    snapshot.rules.asSequence()
                        .map(ManagedAiRule::policy)
                        .filter(runtime::isKnownUnavailable)
                        .toSet()
                }
            }.getOrDefault(emptySet())
        } else {
            emptySet()
        }
        _uiState.update {
            it.copy(
                rules = snapshot.rules,
                availablePolicies = snapshot.availablePolicies,
                unavailablePolicies = unavailable,
                engineRunning = running,
                loading = false,
                busyRuleId = null,
                message = message,
            )
        }
    }

}
