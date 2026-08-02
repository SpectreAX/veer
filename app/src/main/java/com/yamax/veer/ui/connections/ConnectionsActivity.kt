package com.yamax.veer.ui.connections

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.ui.theme.VeerTheme
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeParseException
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
                    onDismissMessage = viewModel::clearMessage
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionsScreen(
    state: ConnectionsUiState,
    onBack: () -> Unit,
    onSearch: (String) -> Unit,
    onSort: (SortMode) -> Unit,
    onCloseConnection: (String) -> Unit,
    onCloseAll: () -> Unit,
    onDismissMessage: () -> Unit
) {
    var searchVisible by remember { mutableStateOf(false) }
    var sortMenuExpanded by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("活跃连接") },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text("返回") }
                },
                actions = {
                    IconButton(onClick = { searchVisible = !searchVisible }) {
                        Icon(Icons.Default.Search, contentDescription = "搜索")
                    }
                    Box {
                        TextButton(onClick = { sortMenuExpanded = true }) {
                            Text("排序")
                        }
                        DropdownMenu(
                            expanded = sortMenuExpanded,
                            onDismissRequest = { sortMenuExpanded = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("按流量") },
                                onClick = { onSort(SortMode.TRAFFIC_DESC); sortMenuExpanded = false }
                            )
                            DropdownMenuItem(
                                text = { Text("按时长") },
                                onClick = { onSort(SortMode.DURATION_DESC); sortMenuExpanded = false }
                            )
                            DropdownMenuItem(
                                text = { Text("按域名") },
                                onClick = { onSort(SortMode.HOST_ASC); sortMenuExpanded = false }
                            )
                        }
                    }
                    TextButton(
                        onClick = onCloseAll,
                        enabled = state.connections.isNotEmpty(),
                    ) {
                        Text("全部断开")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            AnimatedVisibility(visible = searchVisible) {
                OutlinedTextField(
                    value = state.searchQuery,
                    onValueChange = onSearch,
                    placeholder = { Text("搜索域名、规则或节点...") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    singleLine = true,
                    trailingIcon = {
                        if (state.searchQuery.isNotEmpty()) {
                            IconButton(onClick = { onSearch("") }) {
                                Icon(Icons.Default.Close, contentDescription = "清空")
                            }
                        }
                    }
                )
            }

            state.message?.let { message ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .background(
                            MaterialTheme.colorScheme.secondaryContainer,
                            RoundedCornerShape(12.dp)
                        )
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(message, modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismissMessage) { Text("关闭") }
                }
            }

            if (!state.running) {
                EmptyState("VPN 尚未连接")
            } else if (state.loading && state.connections.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else if (state.filteredConnections.isEmpty()) {
                EmptyState(
                    if (state.searchQuery.isBlank()) "暂无活跃连接" else "没有匹配的连接",
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(state.filteredConnections, key = { it.id }) { conn ->
                        ConnectionRow(
                            connection = conn,
                            onClose = { onCloseConnection(conn.id) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionRow(
    connection: MihomoRepository.ConnectionInfo,
    onClose: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp)
    ) {
        Row(
            modifier = Modifier
                .padding(14.dp)
                .fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = connection.host.ifBlank { connection.destinationIP },
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Spacer(Modifier.width(8.dp))
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        shape = RoundedCornerShape(4.dp)
                    ) {
                        Text(
                            text = connection.network.uppercase(),
                            style = MaterialTheme.typography.labelSmall,
                            modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                            color = MaterialTheme.colorScheme.onSecondaryContainer
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                val exitNode = connection.chains.lastOrNull() ?: "DIRECT"
                Text(
                    text = "${connection.rule} → $exitNode",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(4.dp))
                val duration = parseDuration(connection.start)
                Text(
                    text = "↑${formatBytes(connection.upload)}  ↓${formatBytes(connection.download)} · $duration",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            IconButton(onClick = onClose) {
                Icon(Icons.Default.Close, contentDescription = "断开")
            }
        }
    }
}

@Composable
private fun EmptyState(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024L * 1024L * 1024L -> "%.1f GB".format(bytes / (1024.0 * 1024.0 * 1024.0))
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}

private fun parseDuration(startIso: String): String {
    if (startIso.isBlank()) return "0s"
    return try {
        val startInstant = Instant.parse(startIso)
        val now = Instant.now()
        val totalSeconds = Duration.between(startInstant, now).seconds.coerceAtLeast(0L)
        val h = totalSeconds / 3_600
        val m = (totalSeconds / 60) % 60
        val s = totalSeconds % 60
        when {
            h > 0 -> "${h}h ${m}m ${s}s"
            m > 0 -> "${m}m ${s}s"
            else -> "${s}s"
        }
    } catch (e: DateTimeParseException) {
        "0s"
    }
}

private const val CONNECTION_REFRESH_INTERVAL_MS = 2_000L
