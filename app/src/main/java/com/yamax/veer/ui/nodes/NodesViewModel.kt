package com.yamax.veer.ui.nodes

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_profile.SubscriptionMetadata
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.uiText
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.Locale

enum class NodeSortMode { DEFAULT, DELAY_ASC, NAME_ASC, REGION }

data class NodeFilter(
    val sortMode: NodeSortMode = NodeSortMode.DEFAULT,
    val regionFilter: String? = null,
    val hideUnavailable: Boolean = false
)

internal data class NodeUi(
    val name: String,
    val type: String,
    val region: String?,
    val delayMs: Int?,
    val alive: Boolean?,
    val selected: Boolean,
)

internal data class ProxyGroupUi(
    val name: String,
    val type: String,
    val selected: String?,
    val nodes: List<NodeUi>,
    val selectable: Boolean,
)

internal data class NodesUiState(
    val groups: List<ProxyGroupUi> = emptyList(),
    val running: Boolean = false,
    val loading: Boolean = true,
    val busyTarget: String? = null,
    val batchProbeProgress: BatchProbeProgress? = null,
    val message: UiText? = null,
    val error: UiText? = null,
)

internal class NodesViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = MihomoRepository.get()
    private val _uiState = MutableStateFlow(NodesUiState())
    val uiState: StateFlow<NodesUiState> = _uiState.asStateFlow()

    private val _filter = MutableStateFlow(NodeFilter())
    val filter: StateFlow<NodeFilter> = _filter.asStateFlow()

    val availableRegions: StateFlow<List<String>> = _uiState.map { state ->
        state.groups.flatMap { it.nodes }.mapNotNull { it.region }.distinct().sorted()
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val filteredGroups: StateFlow<List<ProxyGroupUi>> =
        combine(_uiState, _filter) { state, filter ->
            filterAndSortGroups(state.groups, filter)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private var probeAllJob: Job? = null

    init {
        viewModelScope.launch {
            AppStateRepository.appState
                .map { it.runtime.engineState is EngineState.Running }
                .distinctUntilChanged()
                .collect { running ->
                    if (!running) {
                        probeAllJob?.cancel()
                        probeAllJob = null
                    }
                    _uiState.update { it.copy(running = running) }
                    refresh()
                }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            val running = AppStateRepository.appState.value.runtime.engineState is EngineState.Running
            if (!running) {
                _uiState.update {
                    it.copy(
                        groups = emptyList(),
                        running = false,
                        loading = false,
                        busyTarget = null,
                        batchProbeProgress = null,
                        error = null,
                    )
                }
                return@launch
            }
            _uiState.update { it.copy(loading = true, running = true, error = null) }
            runCatching { repository.routingSnapshot() }
                .onSuccess { snapshot ->
                    _uiState.update {
                        it.copy(
                            groups = buildGroups(snapshot),
                            running = true,
                            loading = false,
                            busyTarget = null,
                            error = null,
                        )
                    }
                }
                .onFailure { error ->
                    _uiState.update {
                        it.copy(
                            groups = emptyList(),
                            running = true,
                            loading = false,
                            busyTarget = null,
                            error = uiText(
                                R.string.nodes_load_failed,
                                error.message ?: error::class.java.simpleName,
                            ),
                        )
                    }
                }
        }
    }

    fun select(groupName: String, nodeName: String) {
        if (_uiState.value.operationInProgress) return
        viewModelScope.launch {
            _uiState.update { it.copy(busyTarget = groupName, message = null) }
            val success = runCatching { repository.selectProxy(groupName, nodeName) }
                .getOrDefault(false)
            _uiState.update {
                it.copy(
                    message = if (success) {
                        uiText(R.string.nodes_switched, groupName, nodeName)
                    } else {
                        uiText(R.string.nodes_switch_failed)
                    },
                )
            }
            refresh()
        }
    }

    fun autoSelect(groupName: String) {
        if (_uiState.value.operationInProgress) return
        viewModelScope.launch {
            _uiState.update {
                it.copy(
                    busyTarget = groupName,
                    message = uiText(R.string.nodes_measuring_group),
                )
            }
            val snapshot = runCatching { repository.routingSnapshot() }.getOrNull()
            val candidate = runCatching {
                repository.lowestLatencyCandidate(groupName, snapshot)
            }.getOrNull()
            if (candidate == null) {
                _uiState.update {
                    it.copy(
                        busyTarget = null,
                        message = uiText(R.string.nodes_no_candidate),
                    )
                }
                return@launch
            }
            val success = runCatching {
                repository.selectProxy(groupName, candidate.name)
            }.getOrDefault(false)
            _uiState.update {
                it.copy(
                    message = if (success) {
                        candidate.delayMs?.let { delay ->
                            uiText(
                                R.string.nodes_auto_switched_delay,
                                groupName,
                                candidate.name,
                                delay,
                            )
                        } ?: uiText(
                            R.string.nodes_auto_switched,
                            groupName,
                            candidate.name,
                        )
                    } else {
                        uiText(R.string.nodes_candidate_switch_failed)
                    },
                )
            }
            refresh()
        }
    }

    fun probe(nodeName: String) {
        if (_uiState.value.operationInProgress) return
        viewModelScope.launch {
            _uiState.update {
                it.copy(
                    busyTarget = nodeName,
                    message = uiText(R.string.nodes_probing, nodeName),
                )
            }
            val delay = runCatching { repository.probeProxyDelay(nodeName) }.getOrNull()
            _uiState.update {
                it.copy(
                    groups = applyProbeResult(it.groups, nodeName, delay),
                    busyTarget = null,
                    message = delay
                        ?.takeIf { it != UNAVAILABLE_DELAY_MS }
                        ?.let { uiText(R.string.nodes_probe_result, nodeName, it) }
                        ?: uiText(R.string.nodes_probe_failed, nodeName),
                )
            }
        }
    }

    fun probeAll() {
        val initial = _uiState.value
        if (!initial.running || initial.operationInProgress) return
        val targets = uniqueProbeTargets(initial.groups)
        if (targets.isEmpty()) {
            _uiState.update { it.copy(message = uiText(R.string.nodes_no_probe_targets)) }
            return
        }

        _uiState.update {
            it.copy(
                batchProbeProgress = BatchProbeProgress(total = targets.size),
                message = null,
            )
        }
        probeAllJob = viewModelScope.launch {
            try {
                val semaphore = Semaphore(BATCH_PROBE_CONCURRENCY)
                coroutineScope {
                    targets.map { nodeName ->
                        async {
                            val delay = semaphore.withPermit {
                                runCatching {
                                    repository.probeProxyDelay(
                                        proxyName = nodeName,
                                        timeoutMs = BATCH_PROBE_TIMEOUT_MS,
                                    )
                                }.getOrNull()
                            }
                            val success = delay != null && delay != UNAVAILABLE_DELAY_MS
                            _uiState.update { state ->
                                state.copy(
                                    groups = applyProbeResult(state.groups, nodeName, delay),
                                    batchProbeProgress =
                                        state.batchProbeProgress?.record(success),
                                )
                            }
                        }
                    }.awaitAll()
                }

                _uiState.update { state ->
                    val result = state.batchProbeProgress
                    state.copy(
                        batchProbeProgress = null,
                        message = result?.let {
                            uiText(
                                R.string.nodes_probe_complete,
                                it.successful,
                                it.failed,
                            )
                        } ?: uiText(R.string.nodes_probe_finished),
                    )
                }
            } finally {
                _uiState.update { it.copy(batchProbeProgress = null) }
                probeAllJob = null
            }
        }
    }

    fun clearMessage() {
        _uiState.update { it.copy(message = null) }
    }

    fun updateSortMode(mode: NodeSortMode) {
        _filter.update { it.copy(sortMode = mode) }
    }

    fun updateRegionFilter(region: String?) {
        _filter.update {
            it.copy(regionFilter = region?.trim()?.uppercase(Locale.ROOT)?.takeIf(String::isNotEmpty))
        }
    }

    fun toggleHideUnavailable() {
        _filter.update { it.copy(hideUnavailable = !it.hideUnavailable) }
    }

    fun clearFilters() {
        _filter.value = NodeFilter()
    }

    private fun buildGroups(
        snapshot: MihomoRepository.RoutingSnapshot,
    ): List<ProxyGroupUi> = snapshot.proxies.values.asSequence()
        .filter { it.members.isNotEmpty() }
        .filter { it.type in GROUP_TYPES }
        .map { group ->
            ProxyGroupUi(
                name = group.name,
                type = group.type,
                selected = group.now,
                selectable = group.type == "Selector",
                nodes = group.members.asSequence()
                    .filterNot(SubscriptionMetadata::isLikelyMetadataName)
                    .mapNotNull(snapshot.proxies::get)
                    .filter { it.members.isEmpty() }
                    .filter { it.type !in NON_PROXY_TYPES }
                    .map { node ->
                        NodeUi(
                            name = node.name,
                            type = node.type,
                            region = node.regionCode,
                            delayMs = node.delayMs,
                            alive = node.alive,
                            selected = node.name == group.now,
                        )
                    }
                    .toList(),
            )
        }
        .filter { it.nodes.isNotEmpty() }
        .sortedWith(compareByDescending<ProxyGroupUi> { it.selectable }.thenBy { it.name })
        .toList()

    private companion object {
        const val BATCH_PROBE_CONCURRENCY = 4
        const val BATCH_PROBE_TIMEOUT_MS = 3_000
        val GROUP_TYPES = setOf("Selector", "URLTest", "Fallback", "LoadBalance")
        val NON_PROXY_TYPES = setOf(
            "Compatible", "Direct", "Pass", "Reject", "RejectDrop",
        )
    }
}

private val NodesUiState.operationInProgress: Boolean
    get() = busyTarget != null || batchProbeProgress != null

internal fun filterAndSortGroups(
    groups: List<ProxyGroupUi>,
    filter: NodeFilter,
): List<ProxyGroupUi> {
    val requestedRegion = filter.regionFilter?.uppercase(Locale.ROOT)
    return groups.mapNotNull { group ->
        val matchingNodes = group.nodes.filter { node ->
            (requestedRegion == null || node.region.equals(requestedRegion, ignoreCase = true)) &&
                (!filter.hideUnavailable || !node.isUnavailable())
        }
        val sortedNodes = when (filter.sortMode) {
            NodeSortMode.DEFAULT -> matchingNodes
            NodeSortMode.DELAY_ASC -> matchingNodes.sortedWith(nodeDelayComparator)
            NodeSortMode.NAME_ASC -> matchingNodes.sortedWith(
                compareBy(String.CASE_INSENSITIVE_ORDER, NodeUi::name),
            )
            NodeSortMode.REGION -> matchingNodes.sortedWith(
                compareBy<NodeUi, String?>(
                    nullsLast(String.CASE_INSENSITIVE_ORDER),
                    NodeUi::region,
                ).then(nodeDelayComparator),
            )
        }
        group.copy(nodes = sortedNodes).takeIf { sortedNodes.isNotEmpty() }
    }
}

internal fun NodeUi.isUnavailable(): Boolean =
    alive == false || (delayMs != null && delayMs >= UNAVAILABLE_DELAY_MS)

private fun NodeUi.delaySortRank(): Int = when {
    isUnavailable() -> 2
    delayMs == null || delayMs <= 0 -> 1
    else -> 0
}

private val nodeDelayComparator = compareBy<NodeUi> { it.delaySortRank() }
    .thenBy { it.delayMs?.takeIf { delay -> delay > 0 } ?: Int.MAX_VALUE }
    .thenBy(String.CASE_INSENSITIVE_ORDER, NodeUi::name)
