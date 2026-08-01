package com.yamax.veer.ui.logs

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.ui.theme.VeerTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class LogsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                val viewModel: LogViewerViewModel = viewModel()
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                val lifecycleOwner = LocalLifecycleOwner.current
                val context = androidx.compose.ui.platform.LocalContext.current
                val scope = rememberCoroutineScope()
                val snackbarHostState = remember { SnackbarHostState() }
                var pendingExport by remember { mutableStateOf("") }
                val exportLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.CreateDocument("text/plain"),
                ) { uri ->
                    if (uri == null) return@rememberLauncherForActivityResult
                    val text = pendingExport
                    scope.launch {
                        val saved = withContext(Dispatchers.IO) {
                            runCatching {
                                context.contentResolver.openOutputStream(uri, "wt")
                                    ?.bufferedWriter()
                                    ?.use { writer -> writer.write(VeerLog.redact(text)) }
                                    ?: error("无法打开导出文件")
                            }.isSuccess
                        }
                        snackbarHostState.showSnackbar(
                            if (saved) "日志已导出" else "日志导出失败",
                        )
                    }
                }

                LaunchedEffect(lifecycleOwner, state.paused) {
                    if (state.paused) return@LaunchedEffect
                    lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                        while (true) {
                            viewModel.refresh()
                            delay(REFRESH_INTERVAL_MS)
                        }
                    }
                }

                Scaffold(
                    snackbarHost = { SnackbarHost(snackbarHostState) },
                ) { padding ->
                    LogViewerScreen(
                        state = state,
                        onBack = ::finish,
                        onQueryChange = viewModel::setQuery,
                        onSourceChange = viewModel::setSource,
                        onLevelChange = viewModel::setLevel,
                        onTogglePaused = { viewModel.setPaused(!state.paused) },
                        onRefresh = viewModel::requestRefresh,
                        onCopy = {
                            val text = viewModel.exportText()
                            val clipboard =
                                context.getSystemService(ClipboardManager::class.java)
                            clipboard?.setPrimaryClip(
                                ClipData.newPlainText("Veer logs", text),
                            )
                            scope.launch {
                                snackbarHostState.showSnackbar(
                                    if (text.isBlank()) "没有可复制的日志" else "已复制筛选结果",
                                )
                            }
                        },
                        onExport = {
                            pendingExport = viewModel.exportText()
                            exportLauncher.launch("Veer-logs.txt")
                        },
                        modifier = Modifier.padding(padding),
                    )
                }
            }
        }
    }

    private companion object {
        const val REFRESH_INTERVAL_MS = 1_000L
    }
}

@Composable
fun LogViewerScreen(
    state: LogViewerUiState,
    onBack: () -> Unit,
    onQueryChange: (String) -> Unit,
    onSourceChange: (LogSourceFilter) -> Unit,
    onLevelChange: (ViewerLogLevel?) -> Unit,
    onTogglePaused: () -> Unit,
    onRefresh: () -> Unit,
    onCopy: () -> Unit,
    onExport: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val visibleLines = state.visibleLines
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .testTag("log_viewer"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            TextButton(onClick = onBack) { Text("返回") }
            Column {
                Text("实时日志", style = MaterialTheme.typography.titleLarge)
                Text(
                    if (state.paused) "已暂停" else "每秒刷新",
                    style = MaterialTheme.typography.labelSmall,
                )
            }
            Text(
                "${visibleLines.size}/${state.lines.size}",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(top = 14.dp),
            )
        }

        OutlinedTextField(
            value = state.filter.query,
            onValueChange = onQueryChange,
            label = { Text("搜索分类或消息") },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("log_search"),
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SourceFilterChip("全部来源", LogSourceFilter.ALL, state, onSourceChange)
            SourceFilterChip("UI", LogSourceFilter.UI, state, onSourceChange)
            SourceFilterChip("Veercore", LogSourceFilter.CORE, state, onSourceChange)
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LevelFilterChip("全部级别", null, state, onLevelChange)
            LevelFilterChip("Debug", ViewerLogLevel.DEBUG, state, onLevelChange)
            LevelFilterChip("Info", ViewerLogLevel.INFO, state, onLevelChange)
            LevelFilterChip("Warn", ViewerLogLevel.WARN, state, onLevelChange)
            LevelFilterChip("Error", ViewerLogLevel.ERROR, state, onLevelChange)
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Button(onClick = onTogglePaused) {
                Text(if (state.paused) "继续实时" else "暂停")
            }
            OutlinedButton(onClick = onRefresh, enabled = !state.refreshing) {
                Text(if (state.refreshing) "刷新中…" else "刷新")
            }
            OutlinedButton(onClick = onCopy, enabled = visibleLines.isNotEmpty()) {
                Text("复制")
            }
            OutlinedButton(onClick = onExport, enabled = visibleLines.isNotEmpty()) {
                Text("导出")
            }
        }

        state.error?.let {
            Text(
                text = it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
            )
        }

        if (visibleLines.isEmpty()) {
            Text(
                text = if (state.lines.isEmpty()) "暂无日志" else "没有匹配当前筛选的日志",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(16.dp),
            )
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .testTag("log_list"),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(visibleLines, key = ViewerLogLine::id) { line ->
                    LogLineRow(line)
                }
            }
        }
    }
}

@Composable
private fun SourceFilterChip(
    label: String,
    value: LogSourceFilter,
    state: LogViewerUiState,
    onChange: (LogSourceFilter) -> Unit,
) {
    FilterChip(
        selected = state.filter.source == value,
        onClick = { onChange(value) },
        label = { Text(label) },
    )
}

@Composable
private fun LevelFilterChip(
    label: String,
    value: ViewerLogLevel?,
    state: LogViewerUiState,
    onChange: (ViewerLogLevel?) -> Unit,
) {
    FilterChip(
        selected = state.filter.level == value,
        onClick = { onChange(value) },
        label = { Text(label) },
    )
}

@Composable
private fun LogLineRow(line: ViewerLogLine) {
    val background = when (line.level) {
        ViewerLogLevel.ERROR -> MaterialTheme.colorScheme.errorContainer
        ViewerLogLevel.WARN -> MaterialTheme.colorScheme.tertiaryContainer
        else -> MaterialTheme.colorScheme.surfaceVariant
    }
    SelectionContainer {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(background)
                .padding(9.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = "${line.time}  ${line.level.letter ?: '?'}  " +
                    "${line.source.name.lowercase()}/${line.category}",
                style = MaterialTheme.typography.labelSmall,
                color = levelColor(line.level),
            )
            Text(
                text = line.message,
                style = MaterialTheme.typography.bodySmall.copy(
                    fontFamily = FontFamily.Monospace,
                ),
            )
        }
    }
}

@Composable
private fun levelColor(level: ViewerLogLevel): Color = when (level) {
    ViewerLogLevel.ERROR -> MaterialTheme.colorScheme.error
    ViewerLogLevel.WARN -> MaterialTheme.colorScheme.tertiary
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
