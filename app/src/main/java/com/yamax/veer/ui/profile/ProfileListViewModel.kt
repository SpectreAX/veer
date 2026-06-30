package com.yamax.veer.ui.profile

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.parser.message
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

internal class ProfileListViewModel(application: Application) : AndroidViewModel(application) {

    data class UiState(
        val profiles: List<ProfileMetadata> = emptyList(),
        val activeProfileId: ProfileId? = null,
        val importState: ImportState = ImportState.Idle,
        val refreshingIds: Set<String> = emptySet(),
        val isRefreshingAll: Boolean = false,
        val errorBanner: String? = null,
        val editDialog: EditDialog? = null,
        val deleteTarget: ProfileId? = null,
    )

    data class EditDialog(
        val profileId: ProfileId,
        val editedName: String,
    )

    private data class ExtraState(
        val refreshingIds: Set<String> = emptySet(),
        val isRefreshingAll: Boolean = false,
        val errorBanner: String? = null,
        val editDialog: EditDialog? = null,
        val deleteTarget: ProfileId? = null,
    )

    private val _extra = MutableStateFlow(ExtraState())

    val uiState: StateFlow<UiState> = combine(
        AppStateRepository.appState,
        _extra,
    ) { appState, extra ->
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
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState())

    // -------------------------------------------------------------------------
    // Import
    // -------------------------------------------------------------------------

    fun importUrl(url: String) {
        val trimmed = url.trim()
        if (trimmed.isBlank()) return
        viewModelScope.launch {
            val result = ProfileManager.import(getApplication(), ProfileInput.SubscriptionUrl(trimmed))
            if (result is ImportResult.Failure) {
                val msg = result.errors.joinToString("; ") { it.message() }
                VeerLog.profile("importUrl failed: $msg", VeerLog.Level.ERROR)
                _extra.update { it.copy(errorBanner = "Import failed: $msg") }
            }
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
            if (result is ImportResult.Failure) {
                val msg = result.errors.joinToString("; ") { it.message() }
                VeerLog.profile("importYaml failed: $msg", VeerLog.Level.ERROR)
                _extra.update { it.copy(errorBanner = "Import failed: $msg") }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Profile actions
    // -------------------------------------------------------------------------

    fun activate(profileId: ProfileId) {
        viewModelScope.launch {
            ProfileManager.activate(getApplication(), profileId)
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
        _extra.update { it.copy(deleteTarget = null) }
        viewModelScope.launch {
            ProfileManager.delete(getApplication(), id)
        }
    }

    fun refresh(profileId: ProfileId) {
        viewModelScope.launch {
            _extra.update { it.copy(refreshingIds = it.refreshingIds + profileId.value) }
            val result = ProfileManager.refresh(getApplication(), profileId)
            _extra.update { it.copy(refreshingIds = it.refreshingIds - profileId.value) }
            if (result is ImportResult.Failure) {
                val msg = result.errors.joinToString("; ") { it.message() }
                _extra.update { it.copy(errorBanner = "Refresh failed: $msg") }
            }
        }
    }

    fun refreshAll() {
        viewModelScope.launch {
            val urlProfiles = ProfileManager.profiles.value
                .filter { it.source is ProfileSource.SubscriptionUrl }
            if (urlProfiles.isEmpty()) return@launch
            _extra.update { it.copy(isRefreshingAll = true) }
            for (meta in urlProfiles) {
                _extra.update { it.copy(refreshingIds = it.refreshingIds + meta.id.value) }
                val result = ProfileManager.refresh(getApplication(), meta.id)
                _extra.update { it.copy(refreshingIds = it.refreshingIds - meta.id.value) }
                if (result is ImportResult.Failure) {
                    val msg = result.errors.joinToString("; ") { it.message() }
                    _extra.update { it.copy(errorBanner = "\"${meta.displayName}\" refresh failed: $msg") }
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
}
