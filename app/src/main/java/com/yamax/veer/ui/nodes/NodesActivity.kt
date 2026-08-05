package com.yamax.veer.ui.nodes

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerPrimaryButton
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerStateView
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerAlpha
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.designsystem.theme.veerColors
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.navigation.VeerBottomBar
import com.yamax.veer.ui.navigation.VeerTopLevelDestination
import com.yamax.veer.ui.navigation.navigateToTopLevel
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
                    onBack = { navigateToTopLevel(VeerTopLevelDestination.HOME) },
                    onRefresh = viewModel::refresh,
                    onProbeAll = viewModel::probeAll,
                    onSelect = viewModel::select,
                    onAutoSelect = viewModel::autoSelect,
                    onProbe = viewModel::probe,
                    onDismissMessage = viewModel::clearMessage,
                    onUpdateSortMode = viewModel::updateSortMode,
                    onUpdateRegionFilter = viewModel::updateRegionFilter,
                    onToggleHideUnavailable = viewModel::toggleHideUnavailable,
                    onClearFilters = viewModel::clearFilters,
                    showBackNavigation = false,
                    bottomBar = {
                        VeerBottomBar(
                            selected = VeerTopLevelDestination.NODES,
                            onSelect = ::navigateToTopLevel,
                        )
                    },
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
    onClearFilters: () -> Unit,
    showBackNavigation: Boolean = true,
    bottomBar: @Composable () -> Unit = {},
) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.nodes_title),
                onBack = if (showBackNavigation) onBack else null,
                backContentDescription = stringResource(R.string.common_back),
            )
        },
        bottomBar = bottomBar,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = VeerDimensions.contentMaxWidth)
                    .padding(horizontal = VeerSpacing.lg),
            ) {
                VeerStatusBadge(
                    status = if (state.running) VeerStatus.Connected else VeerStatus.Disconnected,
                    label = stringResource(
                        if (state.running) R.string.nodes_runtime_live
                        else R.string.nodes_vpn_disconnected,
                    ),
                )

                FilterRows(
                    filter = filter,
                    availableRegions = availableRegions,
                    onSortChange = onUpdateSortMode,
                    onRegionChange = onUpdateRegionFilter,
                    onHideUnavailableToggle = onToggleHideUnavailable,
                )

                BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                    val compact = maxWidth < VeerDimensions.compactContentBreakpoint
                    val probeEnabled = state.running &&
                        state.groups.isNotEmpty() &&
                        !state.loading &&
                        !state.operationInProgress
                    if (compact) {
                        Column(verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm)) {
                            VeerSecondaryButton(
                                text = stringResource(R.string.common_refresh),
                                onClick = onRefresh,
                                enabled = !state.loading && !state.operationInProgress,
                                modifier = Modifier.fillMaxWidth(),
                            )
                            VeerPrimaryButton(
                                text = stringResource(R.string.nodes_probe_all),
                                onClick = onProbeAll,
                                enabled = probeEnabled,
                                loading = state.batchProbeProgress != null,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag("probe_all_nodes"),
                            )
                        }
                    } else {
                        Row(horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md)) {
                            VeerSecondaryButton(
                                text = stringResource(R.string.common_refresh),
                                onClick = onRefresh,
                                enabled = !state.loading && !state.operationInProgress,
                                modifier = Modifier.weight(1f),
                            )
                            VeerPrimaryButton(
                                text = stringResource(R.string.nodes_probe_all),
                                onClick = onProbeAll,
                                enabled = probeEnabled,
                                loading = state.batchProbeProgress != null,
                                modifier = Modifier
                                    .weight(1f)
                                    .testTag("probe_all_nodes"),
                            )
                        }
                    }
                }

                state.batchProbeProgress?.let { progress ->
                    BatchProbePanel(progress)
                }

                state.message?.let { message ->
                    MessagePanel(message = message.resolve(), onDismiss = onDismissMessage)
                }
            }

            NodesContent(
                state = state,
                filter = filter,
                filteredGroups = filteredGroups,
                onBack = onBack,
                backLabel = stringResource(
                    if (showBackNavigation) R.string.common_back else R.string.bottom_nav_home,
                ),
                onRefresh = onRefresh,
                onClearFilters = onClearFilters,
                onSelect = onSelect,
                onAutoSelect = onAutoSelect,
                onProbe = onProbe,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            )
        }
    }
}

@Composable
private fun FilterRows(
    filter: NodeFilter,
    availableRegions: List<String>,
    onSortChange: (NodeSortMode) -> Unit,
    onRegionChange: (String?) -> Unit,
    onHideUnavailableToggle: () -> Unit,
) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = VeerSpacing.md)
            .testTag("node_sort_filters"),
        horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
    ) {
        item {
            NodeFilterChip(
                selected = filter.sortMode == NodeSortMode.DEFAULT,
                label = stringResource(R.string.nodes_sort_default),
                onClick = { onSortChange(NodeSortMode.DEFAULT) },
                testTag = "node_sort_default",
            )
        }
        item {
            NodeFilterChip(
                selected = filter.sortMode == NodeSortMode.DELAY_ASC,
                label = stringResource(R.string.nodes_sort_delay),
                onClick = { onSortChange(NodeSortMode.DELAY_ASC) },
                testTag = "node_sort_delay",
            )
        }
        item {
            NodeFilterChip(
                selected = filter.sortMode == NodeSortMode.NAME_ASC,
                label = stringResource(R.string.nodes_sort_name),
                onClick = { onSortChange(NodeSortMode.NAME_ASC) },
                testTag = "node_sort_name",
            )
        }
        item {
            NodeFilterChip(
                selected = filter.sortMode == NodeSortMode.REGION,
                label = stringResource(R.string.nodes_sort_region),
                onClick = { onSortChange(NodeSortMode.REGION) },
                testTag = "node_sort_region",
            )
        }
        item {
            NodeFilterChip(
                selected = filter.hideUnavailable,
                label = stringResource(R.string.nodes_hide_unavailable),
                onClick = onHideUnavailableToggle,
                testTag = "node_hide_unavailable",
            )
        }
    }
    if (availableRegions.isNotEmpty()) {
        LazyRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = VeerSpacing.sm)
                .testTag("node_region_filters"),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            item {
                NodeFilterChip(
                    selected = filter.regionFilter == null,
                    label = stringResource(R.string.nodes_region_all),
                    onClick = { onRegionChange(null) },
                    testTag = "node_region_all",
                )
            }
            items(availableRegions, key = { it }) { region ->
                NodeFilterChip(
                    selected = filter.regionFilter == region,
                    label = region,
                    onClick = { onRegionChange(region) },
                    testTag = "node_region_$region",
                )
            }
        }
    } else {
        Spacer(Modifier.size(VeerSpacing.sm))
    }
}

@Composable
private fun NodeFilterChip(
    selected: Boolean,
    label: String,
    onClick: () -> Unit,
    testTag: String,
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        modifier = Modifier.testTag(testTag),
    )
}

@Composable
private fun BatchProbePanel(progress: BatchProbeProgress) {
    Column(
        modifier = Modifier.padding(vertical = VeerSpacing.md),
        verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
    ) {
        Text(
            text = stringResource(
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

@Composable
private fun MessagePanel(message: String, onDismiss: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = VeerSpacing.md),
        color = MaterialTheme.colorScheme.secondaryContainer,
        shape = VeerShapes.medium,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = VeerSpacing.md, vertical = VeerSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = message, modifier = Modifier.weight(1f))
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.common_close))
            }
        }
    }
}

@Composable
private fun NodesContent(
    state: NodesUiState,
    filter: NodeFilter,
    filteredGroups: List<ProxyGroupUi>,
    onBack: () -> Unit,
    backLabel: String,
    onRefresh: () -> Unit,
    onClearFilters: () -> Unit,
    onSelect: (String, String) -> Unit,
    onAutoSelect: (String) -> Unit,
    onProbe: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    when {
        !state.running -> VeerStateView(
            icon = Icons.Default.Info,
            title = stringResource(R.string.nodes_vpn_disconnected),
            description = stringResource(R.string.nodes_start_vpn),
            actionText = backLabel,
            onAction = onBack,
            modifier = modifier,
        )
        state.loading && state.groups.isEmpty() -> VeerStateView(
            title = stringResource(R.string.nodes_runtime_live),
            description = stringResource(R.string.connection_checking),
            loading = true,
            modifier = modifier,
        )
        state.error != null -> VeerStateView(
            icon = Icons.Default.Info,
            title = stringResource(R.string.nodes_load_failed_title),
            description = state.error.resolve(),
            actionText = stringResource(R.string.common_retry),
            onAction = onRefresh,
            modifier = modifier,
        )
        state.groups.isEmpty() -> VeerStateView(
            icon = Icons.Default.Info,
            title = stringResource(R.string.nodes_no_groups),
            actionText = stringResource(R.string.common_retry),
            onAction = onRefresh,
            modifier = modifier,
        )
        filteredGroups.isEmpty() -> VeerStateView(
            icon = Icons.Default.Info,
            title = stringResource(R.string.nodes_no_matches),
            description = if (filter.hideUnavailable || filter.regionFilter != null) {
                stringResource(R.string.nodes_clear_filters)
            } else null,
            actionText = stringResource(R.string.nodes_clear_filters),
            onAction = onClearFilters,
            modifier = modifier,
        )
        else -> LazyColumn(
            modifier = modifier.testTag("proxy_group_list"),
            contentPadding = PaddingValues(VeerSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
        ) {
            items(filteredGroups, key = ProxyGroupUi::name, contentType = { "proxy_group" }) { group ->
                GroupCard(
                    group = group,
                    busyTarget = state.busyTarget,
                    batchProbing = state.batchProbeProgress != null,
                    onSelect = { node -> onSelect(group.name, node) },
                    onAutoSelect = { onAutoSelect(group.name) },
                    onProbe = onProbe,
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
    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("proxy_group_${group.name}"),
    ) {
        Text(
            text = group.name,
            style = MaterialTheme.typography.titleMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = stringResource(
                R.string.nodes_group_status,
                group.type,
                group.selected ?: stringResource(R.string.nodes_unknown),
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
        if (group.selectable) {
            VeerSecondaryButton(
                text = stringResource(R.string.nodes_auto_low_latency),
                onClick = onAutoSelect,
                enabled = busyTarget == null && !batchProbing,
                loading = busyTarget == group.name,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        group.nodes.forEachIndexed { index, node ->
            if (index > 0) HorizontalDivider()
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
    val semanticColor = when (presentation.quality) {
        DelayQuality.UNTESTED -> MaterialTheme.colorScheme.onSurfaceVariant
        DelayQuality.FAST -> MaterialTheme.veerColors.connected
        DelayQuality.MEDIUM -> MaterialTheme.veerColors.connecting
        DelayQuality.SLOW -> MaterialTheme.veerColors.warning
        DelayQuality.UNAVAILABLE -> MaterialTheme.colorScheme.error
    }
    Surface(
        color = semanticColor.copy(alpha = VeerAlpha.disabledContainer),
        shape = VeerShapes.pill,
        modifier = Modifier.testTag("delay_badge_${presentation.quality.name}"),
    ) {
        Text(
            text = presentation.text.resolve(),
            color = semanticColor,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xs),
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
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = if (node.selected) {
            MaterialTheme.colorScheme.secondaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHigh
        },
        shape = VeerShapes.medium,
    ) {
        Column(
            modifier = Modifier.padding(VeerSpacing.md),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                verticalAlignment = Alignment.Top,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = (node.region?.let { "[$it] " } ?: "") + node.name,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = node.type,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                when {
                    busy -> VeerStatusBadge(
                        status = VeerStatus.Loading,
                        label = stringResource(R.string.nodes_switching),
                    )
                    node.selected -> VeerStatusBadge(
                        status = VeerStatus.Connected,
                        label = stringResource(R.string.nodes_selected),
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DelayBadge(delayMs = node.delayMs, alive = node.alive)
                Spacer(modifier = Modifier.weight(1f))
                TextButton(onClick = onProbe, enabled = !busy && !batchProbing) {
                    Text(stringResource(R.string.nodes_probe))
                }
                if (selectable && !node.selected) {
                    TextButton(
                        onClick = onSelect,
                        enabled = !busy && !batchProbing && !node.isUnavailable(),
                    ) {
                        Text(stringResource(R.string.nodes_select))
                    }
                }
            }
        }
    }
}

@VeerThemePreviews
@Composable
private fun NodesScreenPreview() {
    NodesPreviewContent()
}

@VeerResponsivePreviews
@Composable
private fun NodesScreenResponsivePreview() {
    NodesPreviewContent(
        nodeName = "Japan Tokyo premium streaming and AI route with a very long node display name",
    )
}

@Composable
private fun NodesPreviewContent(nodeName: String = "Tokyo 01") {
    val groups = listOf(
        ProxyGroupUi(
            name = "Proxy",
            type = "Selector",
            selected = nodeName,
            selectable = true,
            nodes = listOf(
                NodeUi(nodeName, "VLESS", "JP", 42, true, true),
                NodeUi("Hong Kong 02", "Trojan", "HK", null, null, false),
                NodeUi("Unavailable 03", "Shadowsocks", "US", 65_535, false, false),
            ),
        ),
    )
    VeerPreview {
        NodesScreen(
            state = NodesUiState(groups = groups, running = true, loading = false),
            filter = NodeFilter(),
            availableRegions = listOf("JP", "HK", "US"),
            filteredGroups = groups,
            onBack = {},
            onRefresh = {},
            onProbeAll = {},
            onSelect = { _, _ -> },
            onAutoSelect = {},
            onProbe = {},
            onDismissMessage = {},
            onUpdateSortMode = {},
            onUpdateRegionFilter = {},
            onToggleHideUnavailable = {},
            onClearFilters = {},
        )
    }
}

@VeerThemePreviews
@Composable
private fun NodesLoadingPreview() {
    VeerPreview {
        NodesScreen(
            state = NodesUiState(running = true, loading = true),
            filter = NodeFilter(),
            availableRegions = emptyList(),
            filteredGroups = emptyList(),
            onBack = {}, onRefresh = {}, onProbeAll = {}, onSelect = { _, _ -> },
            onAutoSelect = {}, onProbe = {}, onDismissMessage = {},
            onUpdateSortMode = {}, onUpdateRegionFilter = {},
            onToggleHideUnavailable = {}, onClearFilters = {},
        )
    }
}

@VeerThemePreviews
@Composable
private fun NodesErrorPreview() {
    VeerPreview {
        NodesScreen(
            state = NodesUiState(
                running = true,
                loading = false,
                error = com.yamax.veer.ui.uiText(R.string.nodes_load_failed, "Controller unavailable"),
            ),
            filter = NodeFilter(),
            availableRegions = emptyList(),
            filteredGroups = emptyList(),
            onBack = {}, onRefresh = {}, onProbeAll = {}, onSelect = { _, _ -> },
            onAutoSelect = {}, onProbe = {}, onDismissMessage = {},
            onUpdateSortMode = {}, onUpdateRegionFilter = {},
            onToggleHideUnavailable = {}, onClearFilters = {},
        )
    }
}

private val NodesUiState.operationInProgress: Boolean
    get() = busyTarget != null || batchProbeProgress != null
