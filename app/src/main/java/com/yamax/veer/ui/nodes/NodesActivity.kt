package com.yamax.veer.ui.nodes

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.theme.VeerTheme

class NodesActivity : ComponentActivity() {
    private val viewModel: NodesViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                val filter by viewModel.filter.collectAsStateWithLifecycle()
                val availableRegions by viewModel.availableRegions.collectAsStateWithLifecycle()
                val filteredGroups by viewModel.filteredGroups.collectAsStateWithLifecycle()
                NodesScreen(
                    state = state,
                    filter = filter,
                    availableRegions = availableRegions,
                    filteredGroups = filteredGroups,
                    onBack = ::finish,
                    onRefresh = viewModel::refresh,
                    onProbeAll = viewModel::probeAll,
                    onSelect = viewModel::select,
                    onAutoSelect = viewModel::autoSelect,
                    onProbe = viewModel::probe,
                    onDismissMessage = viewModel::clearMessage,
                    onUpdateSortMode = viewModel::updateSortMode,
                    onUpdateRegionFilter = viewModel::updateRegionFilter,
                    onToggleHideUnavailable = viewModel::toggleHideUnavailable,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
    }
}

@Composable
internal fun NodesScreen(
    state: NodesUiState,
    filter: NodeFilter,
    availableRegions: List<String>,
    filteredGroups: List<ProxyGroupUi>,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onProbeAll: () -> Unit,
    onSelect: (String, String) -> Unit,
    onAutoSelect: (String) -> Unit,
    onProbe: (String) -> Unit,
    onDismissMessage: () -> Unit,
    onUpdateSortMode: (NodeSortMode) -> Unit,
    onUpdateRegionFilter: (String?) -> Unit,
    onToggleHideUnavailable: () -> Unit,
) {
    Scaffold(modifier = Modifier.fillMaxSize()) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TextButton(onClick = onBack) { Text(stringResource(R.string.common_back)) }
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.nodes_title), style = MaterialTheme.typography.headlineSmall)
                    Text(
                        stringResource(
                            if (state.running) R.string.nodes_runtime_live
                            else R.string.nodes_vpn_disconnected,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            FilterRow(
                filter = filter,
                availableRegions = availableRegions,
                onSortChange = onUpdateSortMode,
                onRegionChange = onUpdateRegionFilter,
                onHideUnavailableToggle = onToggleHideUnavailable,
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedButton(
                    onClick = onRefresh,
                    enabled = !state.loading &&
                        state.busyTarget == null &&
                        state.batchProbeProgress == null,
                    modifier = Modifier.weight(1f),
                ) {
                    Text(stringResource(R.string.common_refresh))
                }
                Button(
                    onClick = onProbeAll,
                    enabled = state.running &&
                        state.groups.isNotEmpty() &&
                        !state.loading &&
                        state.busyTarget == null &&
                        state.batchProbeProgress == null,
                    modifier = Modifier
                        .weight(1f)
                        .testTag("probe_all_nodes"),
                ) {
                    Text(stringResource(R.string.nodes_probe_all))
                }
            }

            state.batchProbeProgress?.let { progress ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        stringResource(
                            R.string.nodes_probe_progress,
                            progress.completed,
                            progress.total,
                            progress.successful,
                            progress.failed,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    LinearProgressIndicator(
                        progress = { progress.fraction },
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("probe_all_progress"),
                    )
                }
            }

            state.message?.let { message ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(
                            MaterialTheme.colorScheme.secondaryContainer,
                            RoundedCornerShape(12.dp),
                        )
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(message.resolve(), modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismissMessage) {
                        Text(stringResource(R.string.common_close))
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            when {
                !state.running -> EmptyState(stringResource(R.string.nodes_start_vpn))
                state.loading && state.groups.isEmpty() ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                filteredGroups.isEmpty() -> EmptyState(stringResource(R.string.nodes_no_matches))
                else -> LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag("proxy_group_list"),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(filteredGroups, key = ProxyGroupUi::name) { group ->
                        GroupCard(
                            group = group,
                            busyTarget = state.busyTarget,
                            batchProbing = state.batchProbeProgress != null,
                            onSelect = { node -> onSelect(group.name, node) },
                            onAutoSelect = { onAutoSelect(group.name) },
                            onProbe = onProbe,
                        )
                    }
                    item { Spacer(Modifier.height(18.dp)) }
                }
            }
        }
    }
}

@Composable
private fun FilterRow(
    filter: NodeFilter,
    availableRegions: List<String>,
    onSortChange: (NodeSortMode) -> Unit,
    onRegionChange: (String?) -> Unit,
    onHideUnavailableToggle: () -> Unit,
) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 6.dp)
            .testTag("node_sort_filters"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            FilterChip(
                selected = filter.sortMode == NodeSortMode.DEFAULT,
                onClick = { onSortChange(NodeSortMode.DEFAULT) },
                label = { Text(stringResource(R.string.nodes_sort_default)) },
                modifier = Modifier.testTag("node_sort_default"),
            )
        }
        item {
            FilterChip(
                selected = filter.sortMode == NodeSortMode.DELAY_ASC,
                onClick = { onSortChange(NodeSortMode.DELAY_ASC) },
                label = { Text(stringResource(R.string.nodes_sort_delay)) },
                modifier = Modifier.testTag("node_sort_delay"),
            )
        }
        item {
            FilterChip(
                selected = filter.sortMode == NodeSortMode.NAME_ASC,
                onClick = { onSortChange(NodeSortMode.NAME_ASC) },
                label = { Text(stringResource(R.string.nodes_sort_name)) },
                modifier = Modifier.testTag("node_sort_name"),
            )
        }
        item {
            FilterChip(
                selected = filter.sortMode == NodeSortMode.REGION,
                onClick = { onSortChange(NodeSortMode.REGION) },
                label = { Text(stringResource(R.string.nodes_sort_region)) },
                modifier = Modifier.testTag("node_sort_region"),
            )
        }
        item {
            FilterChip(
                selected = filter.hideUnavailable,
                onClick = onHideUnavailableToggle,
                label = { Text(stringResource(R.string.nodes_hide_unavailable)) },
                modifier = Modifier.testTag("node_hide_unavailable"),
            )
        }
    }
    if (availableRegions.isNotEmpty()) {
        LazyRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 10.dp)
                .testTag("node_region_filters"),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                FilterChip(
                    selected = filter.regionFilter == null,
                    onClick = { onRegionChange(null) },
                    label = { Text(stringResource(R.string.nodes_region_all)) },
                    modifier = Modifier.testTag("node_region_all"),
                )
            }
            items(availableRegions, key = { it }) { region ->
                FilterChip(
                    selected = filter.regionFilter == region,
                    onClick = { onRegionChange(region) },
                    label = { Text(region) },
                    modifier = Modifier.testTag("node_region_$region"),
                )
            }
        }
    }
}

@Composable
private fun GroupCard(
    group: ProxyGroupUi,
    busyTarget: String?,
    batchProbing: Boolean,
    onSelect: (String) -> Unit,
    onAutoSelect: () -> Unit,
    onProbe: (String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("proxy_group_${group.name}")
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
            .border(
                1.dp,
                MaterialTheme.colorScheme.outlineVariant,
                RoundedCornerShape(16.dp),
            )
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(group.name, style = MaterialTheme.typography.titleMedium)
                Text(
                    stringResource(
                        R.string.nodes_group_status,
                        group.type,
                        group.selected ?: stringResource(R.string.nodes_unknown),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (group.selectable) {
                Button(
                    onClick = onAutoSelect,
                    enabled = busyTarget == null && !batchProbing,
                ) {
                    Text(stringResource(R.string.nodes_auto_low_latency))
                }
            }
        }

        group.nodes.forEach { node ->
            NodeRow(
                node = node,
                selectable = group.selectable,
                busy = busyTarget == node.name || busyTarget == group.name,
                batchProbing = batchProbing,
                onSelect = { onSelect(node.name) },
                onProbe = { onProbe(node.name) },
            )
        }
    }
}

@Composable
fun DelayBadge(delayMs: Int?, alive: Boolean?) {
    val presentation = delayPresentation(delayMs, alive)
    val color = when (presentation.quality) {
        DelayQuality.UNTESTED -> MaterialTheme.colorScheme.outline
        DelayQuality.FAST -> Color(0xFF22C55E)
        DelayQuality.MEDIUM -> Color(0xFFEAB308)
        DelayQuality.SLOW,
        DelayQuality.UNAVAILABLE -> Color(0xFFEF4444)
    }
    androidx.compose.material3.Surface(
        color = color.copy(alpha = 0.15f),
        shape = RoundedCornerShape(4.dp),
        modifier = Modifier.testTag("delay_badge_${presentation.quality.name}"),
    ) {
        Text(
            text = presentation.text.resolve(),
            color = color,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun NodeRow(
    node: NodeUi,
    selectable: Boolean,
    busy: Boolean,
    batchProbing: Boolean,
    onSelect: () -> Unit,
    onProbe: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (node.selected) MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surface,
                RoundedCornerShape(12.dp),
            )
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                (node.region?.let { "[$it] " } ?: "") + node.name,
                style = MaterialTheme.typography.bodyMedium,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    if (node.selected) {
                        stringResource(R.string.nodes_node_status_selected, node.type)
                    } else {
                        node.type
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                DelayBadge(delayMs = node.delayMs, alive = node.alive)
            }
        }
        OutlinedButton(onClick = onProbe, enabled = !busy && !batchProbing) {
            Text(stringResource(R.string.nodes_probe))
        }
        if (selectable && !node.selected) {
            TextButton(
                onClick = onSelect,
                enabled = !busy && !batchProbing && !node.isUnavailable(),
            ) { Text(stringResource(R.string.nodes_select)) }
        }
        if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.height(18.dp),
                strokeWidth = 2.dp,
            )
        }
    }
}

@Composable
private fun EmptyState(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
