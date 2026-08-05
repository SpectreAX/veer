package com.yamax.veer.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.CoreRuntimeEvents
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.data.ConnectionHomeStatus
import com.yamax.veer.data.ConnectionStatusRepository
import com.yamax.veer.data.DashboardRefreshCadence
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.chart.SpeedChart
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

@Composable
internal fun ConnectionDashboardSection(
    engineState: EngineState,
    physicalNetworkAvailable: Boolean,
    repository: ConnectionStatusRepository,
) {
    val lifecycleOwner = LocalLifecycleOwner.current
    var status by remember { mutableStateOf(ConnectionHomeStatus()) }
    var refreshing by remember { mutableStateOf(false) }
    val refreshMutex = remember { Mutex() }

    LaunchedEffect(engineState, lifecycleOwner, repository) {
        if (engineState !is EngineState.Running) {
            repository.resetSpeedHistory()
            status = ConnectionHomeStatus()
            refreshing = false
            return@LaunchedEffect
        }
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            repository.resumeSpeedSampling()

            suspend fun refresh(full: Boolean) {
                refreshMutex.withLock {
                    if (full) refreshing = true
                    try {
                        status = if (full) repository.snapshot(status)
                        else repository.trafficSnapshot(status)
                    } finally {
                        if (full) refreshing = false
                    }
                }
            }

            coroutineScope {
                launch {
                    refresh(full = true)
                    while (true) {
                        delay(DashboardRefreshCadence.NETWORK_MS)
                        refresh(full = true)
                    }
                }
                launch {
                    delay(DashboardRefreshCadence.LIGHTWEIGHT_MS)
                    while (true) {
                        refresh(full = false)
                        delay(DashboardRefreshCadence.LIGHTWEIGHT_MS)
                    }
                }
                launch {
                    CoreRuntimeEvents.mutations.collect { refresh(full = true) }
                }
            }
        }
    }

    ConnectionOverviewCard(
        engineState = engineState,
        physicalNetworkAvailable = physicalNetworkAvailable,
        status = status,
        refreshing = refreshing,
    )
    val history by repository.speedHistory.collectAsStateWithLifecycle()
    SpeedChart(
        history = history,
        connected = engineState is EngineState.Running,
        modifier = Modifier.padding(vertical = VeerSpacing.sm),
    )
}

@Composable
private fun ConnectionOverviewCard(
    engineState: EngineState,
    physicalNetworkAvailable: Boolean,
    status: ConnectionHomeStatus,
    refreshing: Boolean,
) {
    val vpnConnected = engineState is EngineState.Running
    val exitIp = listOfNotNull(
        status.exit.ipv4?.let { stringResource(R.string.connection_ipv4, it) },
        status.exit.ipv6?.let { stringResource(R.string.connection_ipv6, it) },
    ).joinToString(" · ").ifEmpty { stringResource(R.string.connection_exit_ip_pending) }
    val route = listOfNotNull(
        status.selectedPolicy?.let { policy ->
            status.runtimeMode?.let { mode ->
                stringResource(R.string.connection_route_mode, policy, mode)
            } ?: policy
        },
        status.selectedNode,
        status.nodeDelayMs?.let { stringResource(R.string.connection_delay_ms, it) },
    ).joinToString(" → ").ifEmpty { stringResource(R.string.connection_route_pending) }

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection_overview"),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = VeerShapes.medium,
    ) {
        Column(
            modifier = Modifier.padding(VeerSpacing.md),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            if (refreshing) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    VeerStatusBadge(
                        status = VeerStatus.Loading,
                        label = stringResource(R.string.connection_checking),
                    )
                }
            }
            StatusLine(
                label = stringResource(R.string.connection_vpn),
                healthy = vpnConnected,
                detail = engineState.localizedLabel(),
            )
            StatusLine(
                label = stringResource(R.string.connection_mihomo),
                healthy = status.controllerReachable,
                detail = stringResource(
                    if (status.controllerReachable) R.string.connection_controller_ready
                    else R.string.connection_controller_unavailable,
                ),
            )
            StatusLine(
                label = stringResource(R.string.connection_internet),
                healthy = status.internetReachable,
                detail = when {
                    !vpnConnected -> stringResource(R.string.connection_not_checked_stopped)
                    !physicalNetworkAvailable -> stringResource(R.string.connection_physical_unavailable)
                    status.internetReachable -> stringResource(
                        R.string.connection_reachable,
                        status.internetLatencyMs?.let {
                            " · ${stringResource(R.string.connection_delay_ms, it)}"
                        }.orEmpty(),
                    )
                    else -> stringResource(R.string.connection_access_failed)
                },
            )
            Text(
                text = stringResource(R.string.connection_exit, status.exit.locationLabel, exitIp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                text = stringResource(R.string.connection_route, route),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                text = stringResource(
                    R.string.connection_traffic,
                    formatBytes(status.downloadTotal),
                    formatBytes(status.uploadTotal),
                    status.activeConnections,
                    status.activeRuleCount,
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun StatusLine(label: String, healthy: Boolean, detail: String) {
    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val compact = maxWidth < VeerDimensions.compactContentBreakpoint
        if (compact) {
            Column(verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs)) {
                VeerStatusBadge(
                    status = if (healthy) VeerStatus.Connected else VeerStatus.Unavailable,
                    label = label,
                )
                Text(
                    text = detail,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        } else {
            Row(
                horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                VeerStatusBadge(
                    status = if (healthy) VeerStatus.Connected else VeerStatus.Unavailable,
                    label = label,
                )
                Text(
                    text = detail,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024L * 1024L * 1024L -> "%.1f GB".format(bytes / (1024.0 * 1024.0 * 1024.0))
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}

@Composable
private fun EngineState.localizedLabel(): String = when (this) {
    EngineState.Stopped -> stringResource(R.string.engine_stopped)
    EngineState.Starting -> stringResource(R.string.engine_starting)
    EngineState.Running -> stringResource(R.string.engine_running)
    EngineState.Stopping -> stringResource(R.string.engine_stopping)
    is EngineState.Error -> stringResource(R.string.engine_error, message)
}

@VeerThemePreviews
@Composable
private fun ConnectionOverviewPreview() {
    ConnectionOverviewPreviewContent()
}

@VeerResponsivePreviews
@Composable
private fun ConnectionOverviewResponsivePreview() {
    ConnectionOverviewPreviewContent(
        node = "Japan Tokyo premium streaming route with a very long node display name",
    )
}

@Composable
private fun ConnectionOverviewPreviewContent(node: String = "Tokyo 01") {
    VeerPreview {
        Column(modifier = Modifier.padding(VeerSpacing.lg)) {
            ConnectionOverviewCard(
                engineState = EngineState.Running,
                physicalNetworkAvailable = true,
                status = ConnectionHomeStatus(
                    controllerReachable = true,
                    selectedPolicy = "Proxy",
                    selectedNode = node,
                    nodeDelayMs = 42,
                    internetReachable = true,
                    internetLatencyMs = 80,
                    downloadTotal = 42L * 1024L * 1024L,
                    uploadTotal = 3L * 1024L * 1024L,
                    activeConnections = 12,
                    activeRuleCount = 3,
                ),
                refreshing = false,
            )
        }
    }
}
