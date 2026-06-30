package com.yamax.veer.ui.profile

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_profile.NormalizedProxyGroup
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.internal.parser.ClashYamlParser
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class ProfileDetailViewModel(
    application: Application,
    val profileId: ProfileId,
) : AndroidViewModel(application) {

    data class ProxyGroupUi(
        val name: String,
        val type: String,
        val proxies: List<String>,
        val selected: String?,
    )

    data class UiState(
        val metadata: ProfileMetadata? = null,
        val proxyGroups: List<ProxyGroupUi> = emptyList(),
        val isLoading: Boolean = true,
        val error: String? = null,
        val switchingGroup: String? = null,
        val vpnRunning: Boolean = false,
    )

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private val repo = MihomoRepository.get()

    init {
        loadProfile()
        observeEngineState()
    }

    private fun loadProfile() {
        viewModelScope.launch {
            val ctx = getApplication<Application>()
            val meta = AppStateRepository.appState.value.profile.profiles.find { it.id == profileId }
            if (meta == null) {
                _uiState.update { it.copy(isLoading = false, error = "Profile not found") }
                return@launch
            }

            val rawYaml = withContext(Dispatchers.IO) {
                ProfileStore.readRawYaml(ctx, profileId)
            }
            if (rawYaml == null) {
                _uiState.update { it.copy(isLoading = false, error = "Profile data not found on disk", metadata = meta) }
                return@launch
            }

            val parseResult = withContext(Dispatchers.Default) {
                ClashYamlParser.parse(rawYaml, profileId, meta.source, meta.displayName)
            }
            if (parseResult.isFailure) {
                val msg = parseResult.exceptionOrNull()?.message ?: "parse error"
                VeerLog.profile("ProfileDetailViewModel parse failed: $msg", VeerLog.Level.ERROR)
                _uiState.update { it.copy(isLoading = false, error = "Failed to read profile: $msg", metadata = meta) }
                return@launch
            }

            val profile = parseResult.getOrThrow()
            val selections = fetchSelections()
            val running = AppStateRepository.appState.value.runtime.engineState is EngineState.Running

            _uiState.update {
                it.copy(
                    metadata    = meta,
                    proxyGroups = buildGroups(profile.proxyGroups, selections),
                    isLoading   = false,
                    vpnRunning  = running,
                )
            }
        }
    }

    private fun observeEngineState() {
        viewModelScope.launch {
            AppStateRepository.appState
                .map { it.runtime.engineState }
                .distinctUntilChanged()
                .collect { engineState ->
                    val running = engineState is EngineState.Running
                    _uiState.update { it.copy(vpnRunning = running) }
                    if (running) refreshSelections()
                }
        }
    }

    private suspend fun fetchSelections(): Map<String, String> {
        if (AppStateRepository.appState.value.runtime.engineState !is EngineState.Running) return emptyMap()
        return runCatching { repo.proxySelections() }.getOrDefault(emptyMap())
    }

    private suspend fun refreshSelections() {
        val selections = runCatching { repo.proxySelections() }.getOrDefault(emptyMap())
        _uiState.update { state ->
            state.copy(
                proxyGroups = state.proxyGroups.map { g ->
                    g.copy(selected = selections[g.name] ?: g.selected)
                }
            )
        }
    }

    private fun buildGroups(
        groups: List<NormalizedProxyGroup>,
        selections: Map<String, String>,
    ): List<ProxyGroupUi> = groups.map { g ->
        ProxyGroupUi(
            name     = g.name,
            type     = g.type,
            proxies  = g.proxies,
            selected = selections[g.name] ?: g.proxies.firstOrNull(),
        )
    }

    fun selectProxy(groupName: String, proxyName: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(switchingGroup = groupName) }
            // Optimistic update
            _uiState.update { state ->
                state.copy(
                    proxyGroups = state.proxyGroups.map { g ->
                        if (g.name == groupName) g.copy(selected = proxyName) else g
                    }
                )
            }
            val ok = runCatching { repo.selectProxy(groupName, proxyName) }.getOrDefault(false)
            if (!ok) {
                VeerLog.profile("selectProxy failed: group=$groupName proxy=$proxyName", VeerLog.Level.WARN)
                refreshSelections()
            }
            _uiState.update { it.copy(switchingGroup = null) }
        }
    }

    class Factory(
        private val application: Application,
        private val profileId: ProfileId,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            ProfileDetailViewModel(application, profileId) as T
    }
}
