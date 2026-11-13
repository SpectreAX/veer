package com.yamax.veer.ui.logs

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.R
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerPrimaryButton
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerStateView
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTextField
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerAlpha
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.designsystem.theme.veerColors
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
                val context = LocalContext.current
                val scope = rememberCoroutineScope()
                val snackbarHostState = remember { SnackbarHostState() }
                val copiedMessage = stringResource(R.string.logs_copy_success)
                val copyEmptyMessage = stringResource(R.string.logs_copy_empty)
                val exportSuccessMessage = stringResource(R.string.logs_export_success)
                val exportFailedMessage = stringResource(R.string.logs_export_failed)
                val clipboardLabel = stringResource(R.string.logs_clipboard_label)
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
                                    ?: error("Unable to open export destination")
                            }.isSuccess
                        }
                        snackbarHostState.showSnackbar(
                            if (saved) exportSuccessMessage else exportFailedMessage,
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
                        context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(
                            ClipData.newPlainText(clipboardLabel, text),
                        )
                        scope.launch {
                            snackbarHostState.showSnackbar(
                                if (text.isBlank()) copyEmptyMessage else copiedMessage,
                            )
                        }
                    },
                    onExport = {
                        pendingExport = viewModel.exportText()
                        exportLauncher.launch(EXPORT_FILE_NAME)
                    },
                    snackbarHost = { SnackbarHost(snackbarHostState) },
                )
            }
        }
    }

    private companion object {
        const val REFRESH_INTERVAL_MS = 1_000L
        const val EXPORT_FILE_NAME = "Veer-logs.txt"
    }
}

@Composable
internal fun LogViewerScreen(
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
    snackbarHost: @Composable () -> Unit = {},
) {
    val visibleLines = state.visibleLines
    val listState = rememberLazyListState()
    val newestLineId = visibleLines.firstOrNull()?.id

    LaunchedEffect(state.paused, newestLineId) {
        if (!state.paused && newestLineId != null) listState.scrollToItem(0)
    }

    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag("log_viewer"),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.logs_title),
                onBack = onBack,
                backContentDescription = stringResource(R.string.common_back),
                actions = {
                    Text(
                        text = stringResource(
                            R.string.logs_visible_count,
                            visibleLines.size,
                            state.lines.size,
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.padding(end = VeerSpacing.lg),
                    )
                },
            )
        },
        snackbarHost = snackbarHost,
    ) { padding ->
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentAlignment = Alignment.TopCenter,
        ) {
            val compactHeight = maxHeight < VeerDimensions.compactContentHeight
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .widthIn(max = VeerDimensions.contentMaxWidth)
                    .padding(horizontal = VeerSpacing.lg, vertical = VeerSpacing.md),
                verticalArrangement = Arrangement.spacedBy(
                    if (compactHeight) VeerSpacing.sm else VeerSpacing.md,
                ),
            ) {
                LogUpdateSummary(state = state, compact = compactHeight)

                VeerTextField(
                    value = state.filter.query,
                    onValueChange = onQueryChange,
                    label = stringResource(R.string.logs_search_label),
                    placeholder = stringResource(R.string.logs_search_placeholder),
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("log_search"),
                )

                LogFilters(
                    state = state,
                    compact = compactHeight,
                    onSourceChange = onSourceChange,
                    onLevelChange = onLevelChange,
                )

                LogActions(
                    state = state,
                    hasVisibleLines = visibleLines.isNotEmpty(),
                    onTogglePaused = onTogglePaused,
                    onRefresh = onRefresh,
                    onCopy = onCopy,
                    onExport = onExport,
                )

                when {
                    state.refreshFailed && state.lines.isEmpty() -> VeerStateView(
                        icon = Icons.Default.Warning,
                        iconContentDescription = null,
                        title = stringResource(R.string.logs_error_title),
                        description = stringResource(R.string.logs_error_description),
                        actionText = stringResource(R.string.common_retry),
                        onAction = onRefresh,
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                    )

                    state.refreshing && state.lines.isEmpty() -> VeerStateView(
                        title = stringResource(R.string.logs_loading),
                        description = stringResource(R.string.logs_loading_description),
                        loading = true,
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                    )

                    visibleLines.isEmpty() -> VeerStateView(
                        icon = Icons.Default.Info,
                        iconContentDescription = null,
                        title = stringResource(
                            if (state.lines.isEmpty()) R.string.logs_empty_title
                            else R.string.logs_filtered_empty_title,
                        ),
                        description = stringResource(
                            if (state.lines.isEmpty()) R.string.logs_empty_description
                            else R.string.logs_filtered_empty_description,
                        ),
                        actionText = if (state.lines.isEmpty()) null
                        else stringResource(R.string.logs_clear_filters),
                        onAction = if (state.lines.isEmpty()) null else {
                            {
                                onQueryChange("")
                                onSourceChange(LogSourceFilter.ALL)
                                onLevelChange(null)
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                    )

                    else -> {
                        if (state.refreshFailed) LogRefreshWarning(onRefresh = onRefresh)
                        LazyColumn(
                            state = listState,
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .testTag("log_list"),
                            verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                        ) {
                            items(visibleLines, key = ViewerLogLine::id) { line ->
                                LogLineRow(line)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LogUpdateSummary(state: LogViewerUiState, compact: Boolean) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerStatusBadge(
                status = when {
                    state.refreshing -> VeerStatus.Loading
                    state.paused -> VeerStatus.Unavailable
                    state.refreshFailed -> VeerStatus.Warning
                    else -> VeerStatus.Connected
                },
                label = stringResource(
                    when {
                        state.refreshing -> R.string.logs_status_refreshing
                        state.paused -> R.string.logs_status_paused
                        state.refreshFailed -> R.string.logs_status_attention
                        else -> R.string.logs_status_live
                    },
                ),
            )
            if (!compact) {
                Text(
                    text = stringResource(
                        if (state.paused) R.string.logs_paused_description
                        else R.string.logs_live_description,
                    ),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun LogFilters(
    state: LogViewerUiState,
    compact: Boolean,
    onSourceChange: (LogSourceFilter) -> Unit,
    onLevelChange: (ViewerLogLevel?) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm)) {
        if (!compact) {
            Text(
                text = stringResource(R.string.logs_filter_source),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelLarge,
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            SourceFilterChip(R.string.logs_source_all, LogSourceFilter.ALL, state, onSourceChange)
            SourceFilterChip(R.string.logs_source_ui, LogSourceFilter.UI, state, onSourceChange)
            SourceFilterChip(R.string.logs_source_core, LogSourceFilter.CORE, state, onSourceChange)
        }
        if (!compact) {
            Text(
                text = stringResource(R.string.logs_filter_level),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelLarge,
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            LevelFilterChip(R.string.logs_level_all, null, state, onLevelChange)
            LevelFilterChip(R.string.logs_level_debug, ViewerLogLevel.DEBUG, state, onLevelChange)
            LevelFilterChip(R.string.logs_level_info, ViewerLogLevel.INFO, state, onLevelChange)
            LevelFilterChip(R.string.logs_level_warn, ViewerLogLevel.WARN, state, onLevelChange)
            LevelFilterChip(R.string.logs_level_error, ViewerLogLevel.ERROR, state, onLevelChange)
        }
    }
}

@Composable
private fun LogActions(
    state: LogViewerUiState,
    hasVisibleLines: Boolean,
    onTogglePaused: () -> Unit,
    onRefresh: () -> Unit,
    onCopy: () -> Unit,
    onExport: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm)) {
            VeerPrimaryButton(
                text = stringResource(
                    if (state.paused) R.string.logs_continue else R.string.logs_pause,
                ),
                onClick = onTogglePaused,
                modifier = Modifier.weight(1f),
            )
            VeerSecondaryButton(
                text = stringResource(R.string.common_refresh),
                onClick = onRefresh,
                enabled = !state.refreshing,
                loading = state.refreshing,
                modifier = Modifier.weight(1f),
            )
        }
        LogTransferActions(
            hasVisibleLines = hasVisibleLines,
            onCopy = onCopy,
            onExport = onExport,
        )
    }
}

@Composable
private fun LogTransferActions(
    hasVisibleLines: Boolean,
    onCopy: () -> Unit,
    onExport: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm)) {
        VeerSecondaryButton(
            text = stringResource(R.string.logs_copy),
            onClick = onCopy,
            enabled = hasVisibleLines,
            modifier = Modifier.weight(1f),
        )
        VeerSecondaryButton(
            text = stringResource(R.string.logs_export),
            onClick = onExport,
            enabled = hasVisibleLines,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun LogRefreshWarning(onRefresh: () -> Unit) {
    VeerCard(
        modifier = Modifier.fillMaxWidth(),
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerStatusBadge(
                status = VeerStatus.Warning,
                label = stringResource(R.string.logs_status_attention),
            )
            Text(
                text = stringResource(R.string.logs_error_kept_existing),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.weight(1f),
            )
            VeerSecondaryButton(
                text = stringResource(R.string.common_retry),
                onClick = onRefresh,
            )
        }
    }
}

@Composable
private fun SourceFilterChip(
    labelResource: Int,
    value: LogSourceFilter,
    state: LogViewerUiState,
    onChange: (LogSourceFilter) -> Unit,
) {
    FilterChip(
        selected = state.filter.source == value,
        onClick = { onChange(value) },
        label = { Text(stringResource(labelResource)) },
    )
}

@Composable
private fun LevelFilterChip(
    labelResource: Int,
    value: ViewerLogLevel?,
    state: LogViewerUiState,
    onChange: (ViewerLogLevel?) -> Unit,
) {
    FilterChip(
        selected = state.filter.level == value,
        onClick = { onChange(value) },
        label = { Text(stringResource(labelResource)) },
    )
}

@Composable
private fun LogLineRow(line: ViewerLogLine) {
    SelectionContainer {
        VeerCard(
            modifier = Modifier.fillMaxWidth(),
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                LogLevelBadge(level = line.level)
                Text(
                    text = line.time,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelMedium,
                )
                Text(
                    text = stringResource(line.source.labelResource),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            Text(
                text = line.category,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelSmall,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = line.message,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            )
        }
    }
}

@Composable
private fun LogLevelBadge(level: ViewerLogLevel) {
    val (container, content) = when (level) {
        ViewerLogLevel.ERROR -> MaterialTheme.colorScheme.errorContainer to
            MaterialTheme.colorScheme.onErrorContainer
        ViewerLogLevel.WARN -> MaterialTheme.veerColors.warning.copy(
            alpha = VeerAlpha.disabledContainer,
        ) to MaterialTheme.veerColors.warning
        ViewerLogLevel.INFO -> MaterialTheme.colorScheme.secondaryContainer to
            MaterialTheme.colorScheme.onSecondaryContainer
        ViewerLogLevel.DEBUG, ViewerLogLevel.UNKNOWN ->
            MaterialTheme.colorScheme.surfaceContainerHighest to
                MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(color = container, contentColor = content, shape = VeerShapes.pill) {
        Text(
            text = stringResource(level.labelResource),
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xs),
        )
    }
}

private val LogSource.labelResource: Int
    get() = when (this) {
        LogSource.UI -> R.string.logs_source_ui
        LogSource.CORE -> R.string.logs_source_core
    }

private val ViewerLogLevel.labelResource: Int
    get() = when (this) {
        ViewerLogLevel.DEBUG -> R.string.logs_level_debug
        ViewerLogLevel.INFO -> R.string.logs_level_info
        ViewerLogLevel.WARN -> R.string.logs_level_warn
        ViewerLogLevel.ERROR -> R.string.logs_level_error
        ViewerLogLevel.UNKNOWN -> R.string.logs_level_unknown
    }

private val PreviewLogLines = listOf(
    ViewerLogLine(
        id = "preview-error",
        time = "10:42:08.271",
        source = LogSource.CORE,
        level = ViewerLogLevel.ERROR,
        category = "connection",
        message = "Could not reach the selected proxy. Existing traffic remains protected.",
    ),
    ViewerLogLine(
        id = "preview-warn",
        time = "10:42:07.119",
        source = LogSource.UI,
        level = ViewerLogLevel.WARN,
        category = "route-check-with-a-very-long-category-name",
        message = "Latency is higher than usual for the selected streaming route. " +
            "This long message verifies that diagnostic text wraps without widening the page.",
    ),
    ViewerLogLine(
        id = "preview-info",
        time = "10:42:06.004",
        source = LogSource.CORE,
        level = ViewerLogLevel.INFO,
        category = "runtime",
        message = "Proxy runtime started successfully.",
    ),
)

@VeerThemePreviews
@Composable
private fun LogViewerNormalPreview() {
    VeerPreview {
        LogViewerScreen(
            state = LogViewerUiState(lines = PreviewLogLines),
            onBack = {}, onQueryChange = {}, onSourceChange = {}, onLevelChange = {},
            onTogglePaused = {}, onRefresh = {}, onCopy = {}, onExport = {},
        )
    }
}

@VeerResponsivePreviews
@Composable
private fun LogViewerResponsivePreview() {
    VeerPreview {
        LogViewerScreen(
            state = LogViewerUiState(lines = PreviewLogLines, paused = true),
            onBack = {}, onQueryChange = {}, onSourceChange = {}, onLevelChange = {},
            onTogglePaused = {}, onRefresh = {}, onCopy = {}, onExport = {},
        )
    }
}

@VeerThemePreviews
@Composable
private fun LogViewerStatesPreview() {
    VeerPreview {
        LogViewerScreen(
            state = LogViewerUiState(refreshFailed = true),
            onBack = {}, onQueryChange = {}, onSourceChange = {}, onLevelChange = {},
            onTogglePaused = {}, onRefresh = {}, onCopy = {}, onExport = {},
        )
    }
}
