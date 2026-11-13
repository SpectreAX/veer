package com.yamax.veer.ui.connections

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerDialog
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerStateView
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTextField
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.theme.VeerTheme
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Locale
import kotlinx.coroutines.delay

class ConnectionsActivity : ComponentActivity() {
    private val viewModel: ConnectionsViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                val lifecycleOwner = LocalLifecycleOwner.current
                LaunchedEffect(lifecycleOwner, state.running) {
                    if (!state.running) return@LaunchedEffect
                    lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                        while (true) {
                            viewModel.refresh()
                            delay(CONNECTION_REFRESH_INTERVAL_MS)
                        }
                    }
                }
                ConnectionsScreen(
                    state = state,
                    onBack = ::finish,
                    onSearch = viewModel::updateSearch,
                    onSort = viewModel::updateSort,
                    onCloseConnection = viewModel::closeConnection,
                    onCloseAll = viewModel::closeAll,
                    onDismissMessage = viewModel::clearMessage,
                )
            }
        }
    }
}

@Composable
internal fun ConnectionsScreen(
    state: ConnectionsUiState,
    onBack: () -> Unit,
    onSearch: (String) -> Unit,
    onSort: (SortMode) -> Unit,
    onCloseConnection: (String) -> Unit,
    onCloseAll: () -> Unit,
    onDismissMessage: () -> Unit,
) {
    var sortMenuExpanded by remember { mutableStateOf(false) }
    var confirmCloseAll by remember { mutableStateOf(false) }

    if (confirmCloseAll) {
        VeerDialog(
            title = stringResource(R.string.connections_close_all_title),
            body = stringResource(R.string.connections_close_all_description),
            confirmText = stringResource(R.string.connections_close_all_confirm),
            onConfirm = {
                confirmCloseAll = false
                onCloseAll()
            },
            dismissText = stringResource(R.string.common_cancel),
            onDismiss = { confirmCloseAll = false },
        )
    }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("connections_screen"),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.connections_title),
                onBack = onBack,
                backContentDescription = stringResource(R.string.common_back),
                actions = {
                    Box {
                        IconButton(
                            onClick = { sortMenuExpanded = true },
                            enabled = state.running && state.connections.isNotEmpty(),
                        ) {
                            Icon(
                                imageVector = Icons.Default.MoreVert,
                                contentDescription = stringResource(R.string.connections_sort),
                            )
                        }
                        DropdownMenu(
                            expanded = sortMenuExpanded,
                            onDismissRequest = { sortMenuExpanded = false },
                        ) {
                            SortMode.entries.forEach { mode ->
                                DropdownMenuItem(
                                    text = { Text(stringResource(mode.labelResource)) },
                                    onClick = {
                                        onSort(mode)
                                        sortMenuExpanded = false
                                    },
                                )
                            }
                        }
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentAlignment = Alignment.TopCenter,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .widthIn(max = VeerDimensions.contentMaxWidth)
                    .padding(horizontal = VeerSpacing.lg, vertical = VeerSpacing.md),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            ) {
                ConnectionsSummary(state = state)

                VeerTextField(
                    value = state.searchQuery,
                    onValueChange = onSearch,
                    label = stringResource(R.string.connections_search_label),
                    placeholder = stringResource(R.string.connections_search_placeholder),
                    enabled = state.running,
                    singleLine = true,
                    trailingIcon = if (state.searchQuery.isEmpty()) null else {
                        {
                            IconButton(onClick = { onSearch("") }) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = stringResource(R.string.common_clear),
                                )
                            }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("connections_search"),
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = stringResource(
                            R.string.connections_sorted_by,
                            stringResource(state.sortMode.labelResource),
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f),
                    )
                    VeerSecondaryButton(
                        text = stringResource(R.string.connections_close_all),
                        onClick = { confirmCloseAll = true },
                        enabled = state.running && state.connections.isNotEmpty(),
                    )
                }

                state.message?.let { message ->
                    VeerCard(
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                        ) {
                            Text(
                                text = message.resolve(),
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.weight(1f),
                            )
                            VeerSecondaryButton(
                                text = stringResource(R.string.common_close),
                                onClick = onDismissMessage,
                            )
                        }
                    }
                }

                ConnectionsContent(
                    state = state,
                    onClearSearch = { onSearch("") },
                    onCloseConnection = onCloseConnection,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun ConnectionsSummary(state: ConnectionsUiState) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerStatusBadge(
                status = when {
                    state.loading -> VeerStatus.Loading
                    state.running -> VeerStatus.Connected
                    else -> VeerStatus.Disconnected
                },
                label = stringResource(
                    when {
                        state.loading -> R.string.connections_status_loading
                        state.running -> R.string.connections_status_live
                        else -> R.string.connections_status_stopped
                    },
                ),
            )
            Text(
                text = stringResource(R.string.connections_count, state.connections.size),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun ConnectionsContent(
    state: ConnectionsUiState,
    onClearSearch: () -> Unit,
    onCloseConnection: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    when {
        !state.running -> VeerStateView(
            icon = Icons.Default.Info,
            iconContentDescription = null,
            title = stringResource(R.string.connections_vpn_stopped_title),
            description = stringResource(R.string.connections_vpn_stopped_description),
            modifier = modifier.fillMaxWidth(),
        )

        state.loading && state.connections.isEmpty() -> VeerStateView(
            title = stringResource(R.string.connections_loading),
            description = stringResource(R.string.connections_loading_description),
            loading = true,
            modifier = modifier.fillMaxWidth(),
        )

        state.filteredConnections.isEmpty() -> VeerStateView(
            icon = Icons.Default.Info,
            iconContentDescription = null,
            title = stringResource(
                if (state.searchQuery.isBlank()) R.string.connections_empty_title
                else R.string.connections_filtered_empty_title,
            ),
            description = stringResource(
                if (state.searchQuery.isBlank()) R.string.connections_empty_description
                else R.string.connections_filtered_empty_description,
            ),
            actionText = if (state.searchQuery.isBlank()) null
            else stringResource(R.string.connections_clear_search),
            onAction = if (state.searchQuery.isBlank()) null else onClearSearch,
            modifier = modifier.fillMaxWidth(),
        )

        else -> LazyColumn(
            modifier = modifier
                .fillMaxWidth()
                .testTag("connections_list"),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            items(state.filteredConnections, key = MihomoRepository.ConnectionInfo::id) { item ->
                ConnectionRow(
                    connection = item,
                    onClose = { onCloseConnection(item.id) },
                )
            }
        }
    }
}

@Composable
private fun ConnectionRow(
    connection: MihomoRepository.ConnectionInfo,
    onClose: () -> Unit,
) {
    val host = connection.host.ifBlank { connection.destinationIP }
    val exitNode = connection.chains.lastOrNull()
        ?: stringResource(R.string.connections_direct)
    val rule = connection.rule.ifBlank { stringResource(R.string.connections_rule_unknown) }
    val duration = durationText(connection.start)

    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection_${connection.id}"),
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
            verticalAlignment = Alignment.Top,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs),
            ) {
                Text(
                    text = host,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ProtocolBadge(connection.network)
                    Text(
                        text = duration,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
            }
            IconButton(onClick = onClose) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = stringResource(R.string.connections_close_one),
                )
            }
        }
        Text(
            text = stringResource(R.string.connections_route, rule, exitNode),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            text = stringResource(
                R.string.connections_traffic,
                formatBytes(connection.upload),
                formatBytes(connection.download),
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun ProtocolBadge(network: String) {
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
        shape = VeerShapes.pill,
    ) {
        Text(
            text = network.uppercase(Locale.ROOT),
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xs),
        )
    }
}

@Composable
private fun durationText(startIso: String): String {
    val duration = parseDuration(startIso)
    return when {
        duration.hours > 0 -> stringResource(
            R.string.connections_duration_hms,
            duration.hours,
            duration.minutes,
            duration.seconds,
        )
        duration.minutes > 0 -> stringResource(
            R.string.connections_duration_ms,
            duration.minutes,
            duration.seconds,
        )
        else -> stringResource(R.string.connections_duration_s, duration.seconds)
    }
}

private data class ConnectionDuration(
    val hours: Long,
    val minutes: Long,
    val seconds: Long,
)

private fun parseDuration(startIso: String): ConnectionDuration {
    if (startIso.isBlank()) return ConnectionDuration(0, 0, 0)
    val totalSeconds = try {
        Duration.between(Instant.parse(startIso), Instant.now()).seconds.coerceAtLeast(0L)
    } catch (_: DateTimeParseException) {
        0L
    }
    return ConnectionDuration(
        hours = totalSeconds / 3_600,
        minutes = (totalSeconds / 60) % 60,
        seconds = totalSeconds % 60,
    )
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= GIB -> String.format(Locale.US, "%.1f GB", bytes / GIB.toDouble())
    bytes >= MIB -> String.format(Locale.US, "%.1f MB", bytes / MIB.toDouble())
    bytes >= KIB -> String.format(Locale.US, "%.1f KB", bytes / KIB.toDouble())
    else -> "$bytes B"
}

private val SortMode.labelResource: Int
    get() = when (this) {
        SortMode.TRAFFIC_DESC -> R.string.connections_sort_traffic
        SortMode.DURATION_DESC -> R.string.connections_sort_duration
        SortMode.HOST_ASC -> R.string.connections_sort_host
    }

private val PreviewConnections = listOf(
    MihomoRepository.ConnectionInfo(
        id = "preview-stream",
        host = "very-long-streaming-service.example.com",
        destinationIP = "203.0.113.42",
        network = "tcp",
        type = "HTTPS",
        chains = listOf("Japan Tokyo premium streaming and AI route"),
        rule = "Netflix and streaming services",
        rulePayload = "",
        download = 84L * MIB,
        upload = 3L * MIB,
        start = "",
    ),
    MihomoRepository.ConnectionInfo(
        id = "preview-direct",
        host = "updates.example.org",
        destinationIP = "198.51.100.8",
        network = "udp",
        type = "QUIC",
        chains = emptyList(),
        rule = "DIRECT",
        rulePayload = "",
        download = 512L * KIB,
        upload = 48L * KIB,
        start = "",
    ),
)

@VeerThemePreviews
@Composable
private fun ConnectionsNormalPreview() {
    VeerPreview {
        ConnectionsScreen(
            state = ConnectionsUiState(
                connections = PreviewConnections,
                filteredConnections = PreviewConnections,
                loading = false,
                running = true,
            ),
            onBack = {}, onSearch = {}, onSort = {}, onCloseConnection = {},
            onCloseAll = {}, onDismissMessage = {},
        )
    }
}

@VeerResponsivePreviews
@Composable
private fun ConnectionsResponsivePreview() {
    VeerPreview {
        ConnectionsScreen(
            state = ConnectionsUiState(
                connections = PreviewConnections,
                filteredConnections = PreviewConnections,
                loading = false,
                running = true,
            ),
            onBack = {}, onSearch = {}, onSort = {}, onCloseConnection = {},
            onCloseAll = {}, onDismissMessage = {},
        )
    }
}

@VeerThemePreviews
@Composable
private fun ConnectionsStoppedPreview() {
    VeerPreview {
        ConnectionsScreen(
            state = ConnectionsUiState(loading = false, running = false),
            onBack = {}, onSearch = {}, onSort = {}, onCloseConnection = {},
            onCloseAll = {}, onDismissMessage = {},
        )
    }
}

private const val CONNECTION_REFRESH_INTERVAL_MS = 2_000L
private const val KIB = 1_024L
private const val MIB = KIB * 1_024L
private const val GIB = MIB * 1_024L
