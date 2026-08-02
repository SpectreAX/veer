package com.yamax.veer.ui.logs

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.core_logging.VeerLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class LogViewerUiState(
    val lines: List<ViewerLogLine> = emptyList(),
    val filter: LogViewerFilter = LogViewerFilter(),
    val paused: Boolean = false,
    val refreshing: Boolean = false,
    val error: String? = null,
) {
    val visibleLines: List<ViewerLogLine>
        get() = LogViewerFiltering.apply(lines, filter)
}

class LogViewerViewModel : ViewModel() {
    private val repository = LogViewerRepository()
    private val refreshMutex = Mutex()
    private val _uiState = MutableStateFlow(LogViewerUiState())
    val uiState: StateFlow<LogViewerUiState> = _uiState.asStateFlow()

    suspend fun refresh() {
        refreshMutex.withLock {
            _uiState.update { it.copy(refreshing = true, error = null) }
            val result = withContext(Dispatchers.IO) {
                runCatching(repository::snapshot)
            }
            _uiState.update { current ->
                result.fold(
                    onSuccess = { current.copy(lines = it, refreshing = false) },
                    onFailure = {
                        current.copy(
                            refreshing = false,
                            error = it.message ?: "日志刷新失败",
                        )
                    },
                )
            }
        }
    }

    fun requestRefresh() {
        viewModelScope.launch { refresh() }
    }

    fun setPaused(paused: Boolean) {
        _uiState.update { it.copy(paused = paused) }
        if (!paused) requestRefresh()
    }

    fun setQuery(query: String) {
        _uiState.update { it.copy(filter = it.filter.copy(query = query)) }
    }

    fun setSource(source: LogSourceFilter) {
        _uiState.update { it.copy(filter = it.filter.copy(source = source)) }
    }

    fun setLevel(level: ViewerLogLevel?) {
        _uiState.update { it.copy(filter = it.filter.copy(level = level)) }
    }

    fun exportText(): String = _uiState.value.visibleLines
        .joinToString(separator = "\n", postfix = "\n") { line ->
            VeerLog.redact(line.formatted())
        }
}
