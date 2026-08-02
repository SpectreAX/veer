package com.yamax.veer.ui.connections

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoRepository
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Locale
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class SortMode {
    TRAFFIC_DESC,
    DURATION_DESC,
    HOST_ASC,
}

data class ConnectionsUiState(
    val connections: List<MihomoRepository.ConnectionInfo> = emptyList(),
    val filteredConnections: List<MihomoRepository.ConnectionInfo> = emptyList(),
    val searchQuery: String = "",
    val sortMode: SortMode = SortMode.TRAFFIC_DESC,
    val loading: Boolean = true,
    val message: String? = null,
    val running: Boolean = false,
)

internal interface ConnectionsGateway {
    suspend fun loadConnections(): Result<List<MihomoRepository.ConnectionInfo>>
    suspend fun closeConnection(id: String): Boolean
    suspend fun closeAllConnections(): Boolean
}

private class MihomoConnectionsGateway(
    private val repository: MihomoRepository = MihomoRepository.get(),
) : ConnectionsGateway {
    override suspend fun loadConnections(): Result<List<MihomoRepository.ConnectionInfo>> =
        repository.getConnectionDetails()

    override suspend fun closeConnection(id: String): Boolean =
        repository.closeConnection(id)

    override suspend fun closeAllConnections(): Boolean =
        repository.closeAllConnections()
}

class ConnectionsViewModel internal constructor(
    private val gateway: ConnectionsGateway,
    runningFlow: Flow<Boolean>,
) : ViewModel() {

    constructor() : this(
        gateway = MihomoConnectionsGateway(),
        runningFlow = AppStateRepository.appState
            .map { it.runtime.engineState is EngineState.Running },
    )

    private val _uiState = MutableStateFlow(ConnectionsUiState())
    val uiState: StateFlow<ConnectionsUiState> = _uiState.asStateFlow()
    private var refreshJob: Job? = null

    init {
        viewModelScope.launch {
            runningFlow
                .distinctUntilChanged()
                .collect { running ->
                    if (running) {
                        _uiState.update {
                            it.copy(
                                running = true,
                                loading = it.connections.isEmpty(),
                            )
                        }
                    } else {
                        refreshJob?.cancel()
                        refreshJob = null
                        _uiState.update {
                            it.copy(
                                running = false,
                                connections = emptyList(),
                                filteredConnections = emptyList(),
                                loading = false,
                            )
                        }
                    }
                }
        }
    }

    /**
     * Performs one refresh. The Activity owns the two-second loop so polling
     * exists only while its lifecycle is RESUMED.
     */
    fun refresh() {
        if (!_uiState.value.running || refreshJob?.isActive == true) return
        refreshJob = viewModelScope.launch {
            val result = gateway.loadConnections()
            result.fold(
                onSuccess = { list ->
                    _uiState.update { state ->
                        state.copy(
                            connections = list,
                            filteredConnections = filterAndSortConnections(
                                list = list,
                                query = state.searchQuery,
                                sortMode = state.sortMode,
                            ),
                            loading = false,
                        )
                    }
                },
                onFailure = {
                    _uiState.update {
                        it.copy(
                            loading = false,
                            message = "刷新连接失败，请确认代理核心正在运行",
                        )
                    }
                },
            )
        }
    }

    fun updateSearch(query: String) {
        _uiState.update { state ->
            state.copy(
                searchQuery = query,
                filteredConnections = filterAndSortConnections(
                    state.connections,
                    query,
                    state.sortMode,
                ),
            )
        }
    }

    fun updateSort(mode: SortMode) {
        _uiState.update { state ->
            state.copy(
                sortMode = mode,
                filteredConnections = filterAndSortConnections(
                    state.connections,
                    state.searchQuery,
                    mode,
                ),
            )
        }
    }

    fun closeConnection(id: String) {
        if (id.isBlank()) {
            _uiState.update { it.copy(message = "无效的连接标识") }
            return
        }
        viewModelScope.launch {
            if (gateway.closeConnection(id)) {
                removeConnections { it.id == id }
            } else {
                _uiState.update { it.copy(message = "关闭连接失败") }
            }
        }
    }

    fun closeAll() {
        viewModelScope.launch {
            if (gateway.closeAllConnections()) {
                removeConnections { true }
                _uiState.update { it.copy(message = "已关闭所有连接") }
            } else {
                _uiState.update { it.copy(message = "关闭所有连接失败") }
            }
        }
    }

    fun clearMessage() {
        _uiState.update { it.copy(message = null) }
    }

    private fun removeConnections(predicate: (MihomoRepository.ConnectionInfo) -> Boolean) {
        _uiState.update { state ->
            val remaining = state.connections.filterNot(predicate)
            state.copy(
                connections = remaining,
                filteredConnections = filterAndSortConnections(
                    remaining,
                    state.searchQuery,
                    state.sortMode,
                ),
            )
        }
    }
}

internal fun filterAndSortConnections(
    list: List<MihomoRepository.ConnectionInfo>,
    query: String,
    sortMode: SortMode,
): List<MihomoRepository.ConnectionInfo> {
    val normalizedQuery = query.trim().lowercase(Locale.ROOT)
    val filtered = if (normalizedQuery.isEmpty()) {
        list
    } else {
        list.filter { connection ->
            connection.host.lowercase(Locale.ROOT).contains(normalizedQuery) ||
                connection.destinationIP.lowercase(Locale.ROOT).contains(normalizedQuery) ||
                connection.rule.lowercase(Locale.ROOT).contains(normalizedQuery) ||
                connection.rulePayload.lowercase(Locale.ROOT).contains(normalizedQuery) ||
                connection.chains.any { chain ->
                    chain.lowercase(Locale.ROOT).contains(normalizedQuery)
                }
        }
    }

    return when (sortMode) {
        SortMode.TRAFFIC_DESC -> filtered.sortedByDescending(::totalTraffic)
        SortMode.DURATION_DESC -> filtered.sortedWith(
            compareBy<MihomoRepository.ConnectionInfo>(::startEpochMillis)
                .thenBy { displayHost(it).lowercase(Locale.ROOT) },
        )
        SortMode.HOST_ASC -> filtered.sortedBy {
            displayHost(it).lowercase(Locale.ROOT)
        }
    }
}

private fun totalTraffic(connection: MihomoRepository.ConnectionInfo): Long {
    val upload = connection.upload.coerceAtLeast(0L)
    val download = connection.download.coerceAtLeast(0L)
    return if (Long.MAX_VALUE - upload < download) Long.MAX_VALUE else upload + download
}

private fun startEpochMillis(connection: MihomoRepository.ConnectionInfo): Long {
    if (connection.start.isBlank()) return Long.MAX_VALUE
    return try {
        Instant.parse(connection.start).toEpochMilli()
    } catch (_: DateTimeParseException) {
        Long.MAX_VALUE
    }
}

private fun displayHost(connection: MihomoRepository.ConnectionInfo): String =
    connection.host.ifBlank { connection.destinationIP }
