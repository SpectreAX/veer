package com.yamax.veer.ui.perapp

import android.app.Application
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.data.PerAppProxyPolicyStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class PerAppProxyUiState(
    val loading: Boolean = true,
    val saving: Boolean = false,
    val mode: PerAppProxyMode = PerAppProxyMode.ALL_APPS,
    val selectedPackages: Set<String> = emptySet(),
    val apps: List<InstalledAppEntry> = emptyList(),
    val message: String? = null,
) {
    val availableSelectedCount: Int
        get() = apps.count { it.isAvailable && it.packageName in selectedPackages }

    val canSave: Boolean
        get() = !loading &&
            !saving &&
            (mode != PerAppProxyMode.ONLY_SELECTED || availableSelectedCount > 0)
}

internal class PerAppProxyViewModel(application: Application) : AndroidViewModel(application) {
    private val _uiState = MutableStateFlow(PerAppProxyUiState())
    val uiState: StateFlow<PerAppProxyUiState> = _uiState.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(loading = true, message = null)
            val loaded = withContext(Dispatchers.IO) {
                val context = getApplication<Application>()
                val policy = PerAppProxyPolicyStore.read(context)
                val available = InstalledAppRepository.launchableApps(context)
                val knownPackages = available.mapTo(mutableSetOf(), InstalledAppEntry::packageName)
                val stale = policy.packageNames
                    .filterNot(knownPackages::contains)
                    .sorted()
                    .map { packageName ->
                        InstalledAppEntry(
                            label = packageName,
                            packageName = packageName,
                            isSystemApp = false,
                            isAvailable = false,
                        )
                    }
                Triple(policy, available + stale, stale.size)
            }
            _uiState.value = PerAppProxyUiState(
                loading = false,
                mode = loaded.first.mode,
                selectedPackages = loaded.first.packageNames,
                apps = loaded.second,
                message = if (loaded.third > 0) {
                    "有 ${loaded.third} 个已选应用当前不可用，可取消选择后保存。"
                } else {
                    null
                },
            )
        }
    }

    fun setMode(mode: PerAppProxyMode) {
        _uiState.value = _uiState.value.copy(mode = mode, message = null)
    }

    fun togglePackage(packageName: String) {
        val current = _uiState.value
        val updated = current.selectedPackages.toMutableSet().apply {
            if (!add(packageName)) remove(packageName)
        }
        _uiState.value = current.copy(selectedPackages = updated, message = null)
    }

    fun selectVisible(packageNames: Set<String>) {
        val current = _uiState.value
        _uiState.value = current.copy(
            selectedPackages = current.selectedPackages + packageNames,
            message = null,
        )
    }

    fun clearSelection() {
        _uiState.value = _uiState.value.copy(
            selectedPackages = emptySet(),
            message = null,
        )
    }

    fun save(runtimeRunning: Boolean) {
        val snapshot = _uiState.value
        if (!snapshot.canSave) {
            _uiState.value = snapshot.copy(
                message = "“仅代理所选应用”至少需要选择一个当前可用的应用。",
            )
            return
        }
        _uiState.value = snapshot.copy(saving = true, message = null)
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    PerAppProxyPolicyStore.write(
                        getApplication(),
                        PerAppProxyPolicy(
                            mode = snapshot.mode,
                            packageNames = snapshot.selectedPackages,
                        ),
                    )
                }
            }
            result.onSuccess {
                if (runtimeRunning) {
                    runCatching {
                        ContextCompat.startForegroundService(
                            getApplication(),
                            VeerVpnService.reconnectIntent(getApplication()),
                        )
                    }.onFailure { error ->
                        VeerLog.core(
                            "[per-app] saved but reconnect failed: ${error.message}",
                            VeerLog.Level.WARN,
                        )
                    }
                }
            }
            _uiState.value = _uiState.value.copy(
                saving = false,
                message = result.fold(
                    onSuccess = {
                        if (runtimeRunning) {
                            "已保存，正在快速重连以应用新的分流范围。"
                        } else {
                            "已保存，下次连接时生效。"
                        }
                    },
                    onFailure = { "保存失败：${it.message ?: "未知错误"}" },
                ),
            )
        }
    }

    fun dismissMessage() {
        _uiState.value = _uiState.value.copy(message = null)
    }
}
