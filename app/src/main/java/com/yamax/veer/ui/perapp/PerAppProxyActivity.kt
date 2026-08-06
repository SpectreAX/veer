package com.yamax.veer.ui.perapp

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerPrimaryButton
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerSettingsRow
import com.yamax.veer.ui.designsystem.components.VeerStateView
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTextField
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerElevation
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.theme.VeerTheme

class PerAppProxyActivity : ComponentActivity() {
    private val viewModel: PerAppProxyViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                val appState by AppStateRepository.appState.collectAsStateWithLifecycle()
                PerAppProxyScreen(
                    state = state,
                    runtimeRunning = appState.runtime.engineState is EngineState.Running,
                    onBack = ::finish,
                    onRetry = viewModel::refresh,
                    onModeChange = viewModel::setMode,
                    onTogglePackage = viewModel::togglePackage,
                    onSelectVisible = viewModel::selectVisible,
                    onClearSelection = viewModel::clearSelection,
                    onSave = viewModel::save,
                    onDismissMessage = viewModel::dismissMessage,
                )
            }
        }
    }
}

@Composable
internal fun PerAppProxyScreen(
    state: PerAppProxyUiState,
    runtimeRunning: Boolean,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onModeChange: (PerAppProxyMode) -> Unit,
    onTogglePackage: (String) -> Unit,
    onSelectVisible: (Set<String>) -> Unit,
    onClearSelection: () -> Unit,
    onSave: (Boolean) -> Unit,
    onDismissMessage: () -> Unit,
) {
    var query by remember { mutableStateOf(TextFieldValue("")) }
    val visibleApps = remember(state.apps, query.text) {
        val needle = query.text.trim()
        if (needle.isEmpty()) {
            state.apps
        } else {
            state.apps.filter {
                it.label.contains(needle, ignoreCase = true) ||
                    it.packageName.contains(needle, ignoreCase = true)
            }
        }
    }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("per_app_screen"),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.per_app_title),
                onBack = onBack,
                backContentDescription = stringResource(R.string.common_back),
            )
        },
        bottomBar = {
            if (!state.loading && !state.loadFailed) {
                Surface(tonalElevation = VeerElevation.low) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(
                                horizontal = VeerSpacing.lg,
                                vertical = VeerSpacing.md,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        VeerPrimaryButton(
                            text = when {
                                state.saving -> stringResource(R.string.per_app_saving)
                                runtimeRunning -> stringResource(R.string.per_app_save_reconnect)
                                else -> stringResource(R.string.common_save)
                            },
                            onClick = { onSave(runtimeRunning) },
                            enabled = state.canSave,
                            loading = state.saving,
                            modifier = Modifier
                                .fillMaxWidth()
                                .widthIn(max = VeerDimensions.formMaxWidth)
                                .testTag("save_per_app_policy"),
                        )
                    }
                }
            }
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentAlignment = Alignment.TopCenter,
        ) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .widthIn(max = VeerDimensions.formMaxWidth)
                    .testTag("per_app_list"),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = VeerSpacing.lg,
                    vertical = VeerSpacing.lg,
                ),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            ) {
                item(key = "runtime") {
                    PerAppRuntimeSummary(runtimeRunning = runtimeRunning)
                }

                when {
                    state.loading -> item(key = "loading") {
                        VeerStateView(
                            title = stringResource(R.string.per_app_loading),
                            description = stringResource(R.string.per_app_loading_description),
                            loading = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }

                    state.loadFailed -> item(key = "load_error") {
                        VeerStateView(
                            title = stringResource(R.string.per_app_load_failed_title),
                            description = state.message?.resolve(),
                            actionText = stringResource(R.string.common_retry),
                            onAction = onRetry,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }

                    else -> {
                        item(key = "mode_heading") {
                            Text(
                                text = stringResource(R.string.per_app_section_mode),
                                style = MaterialTheme.typography.titleLarge,
                            )
                        }
                        item(key = "modes") {
                            PerAppModeCard(selected = state.mode, onModeChange = onModeChange)
                        }

                        state.message?.let { message ->
                            item(key = "message") {
                                PerAppMessageCard(
                                    message = message.resolve(),
                                    kind = state.messageKind,
                                    onDismiss = onDismissMessage,
                                )
                            }
                        }

                        if (state.mode == PerAppProxyMode.ALL_APPS) {
                            item(key = "all_apps_info") {
                                VeerCard(modifier = Modifier.fillMaxWidth()) {
                                    Text(
                                        text = stringResource(R.string.per_app_all_apps_title),
                                        style = MaterialTheme.typography.titleMedium,
                                    )
                                    Text(
                                        text = stringResource(R.string.per_app_all_apps_description),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        style = MaterialTheme.typography.bodyMedium,
                                    )
                                }
                            }
                        } else {
                            item(key = "apps_heading") {
                                Text(
                                    text = stringResource(R.string.per_app_section_apps),
                                    style = MaterialTheme.typography.titleLarge,
                                )
                            }
                            item(key = "search") {
                                VeerTextField(
                                    value = query,
                                    onValueChange = { query = it },
                                    label = stringResource(R.string.per_app_search_label),
                                    placeholder = stringResource(R.string.per_app_search_placeholder),
                                    singleLine = true,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .testTag("per_app_search"),
                                )
                            }
                            item(key = "selection_actions") {
                                PerAppSelectionActions(
                                    selectedCount = state.selectedPackages.size,
                                    availableSelectedCount = state.availableSelectedCount,
                                    canSelectVisible = visibleApps.any(InstalledAppEntry::isAvailable),
                                    canClear = state.selectedPackages.isNotEmpty(),
                                    onSelectVisible = {
                                        onSelectVisible(
                                            visibleApps
                                                .filter(InstalledAppEntry::isAvailable)
                                                .mapTo(mutableSetOf(), InstalledAppEntry::packageName),
                                        )
                                    },
                                    onClear = onClearSelection,
                                )
                            }

                            when {
                                state.apps.isEmpty() -> item(key = "empty_apps") {
                                    VeerStateView(
                                        title = stringResource(R.string.per_app_empty_title),
                                        description = stringResource(R.string.per_app_empty_description),
                                        actionText = stringResource(R.string.common_retry),
                                        onAction = onRetry,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                }

                                visibleApps.isEmpty() -> item(key = "empty_search") {
                                    VeerStateView(
                                        title = stringResource(R.string.per_app_no_matches_title),
                                        description = stringResource(
                                            R.string.per_app_no_matches_description,
                                            query.text,
                                        ),
                                        actionText = stringResource(R.string.common_clear),
                                        onAction = { query = TextFieldValue("") },
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                }
                            }

                            items(visibleApps, key = InstalledAppEntry::packageName) { app ->
                                AppSelectionCard(
                                    app = app,
                                    selected = app.packageName in state.selectedPackages,
                                    onToggle = { onTogglePackage(app.packageName) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PerAppRuntimeSummary(runtimeRunning: Boolean) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        VeerStatusBadge(
            status = if (runtimeRunning) VeerStatus.Connected else VeerStatus.Disconnected,
            label = stringResource(
                if (runtimeRunning) R.string.per_app_runtime_connected
                else R.string.per_app_runtime_disconnected,
            ),
        )
        Text(
            text = stringResource(
                if (runtimeRunning) R.string.per_app_runtime_connected_description
                else R.string.per_app_runtime_disconnected_description,
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun PerAppModeCard(
    selected: PerAppProxyMode,
    onModeChange: (PerAppProxyMode) -> Unit,
) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        PerAppModeRow(
            mode = PerAppProxyMode.ALL_APPS,
            title = stringResource(R.string.per_app_mode_all),
            description = stringResource(R.string.per_app_mode_all_description),
            selected = selected,
            onModeChange = onModeChange,
        )
        PerAppModeRow(
            mode = PerAppProxyMode.ONLY_SELECTED,
            title = stringResource(R.string.per_app_mode_only),
            description = stringResource(R.string.per_app_mode_only_description),
            selected = selected,
            onModeChange = onModeChange,
        )
        PerAppModeRow(
            mode = PerAppProxyMode.BYPASS_SELECTED,
            title = stringResource(R.string.per_app_mode_bypass),
            description = stringResource(R.string.per_app_mode_bypass_description),
            selected = selected,
            onModeChange = onModeChange,
        )
    }
}

@Composable
private fun PerAppModeRow(
    mode: PerAppProxyMode,
    title: String,
    description: String,
    selected: PerAppProxyMode,
    onModeChange: (PerAppProxyMode) -> Unit,
) {
    VeerSettingsRow(
        title = title,
        description = description,
        trailingContent = {
            RadioButton(selected = selected == mode, onClick = { onModeChange(mode) })
        },
        onClick = { onModeChange(mode) },
        modifier = Modifier.testTag("per_app_mode_${mode.name}"),
    )
}

@Composable
private fun PerAppMessageCard(
    message: String,
    kind: PerAppMessageKind,
    onDismiss: () -> Unit,
) {
    VeerCard(
        modifier = Modifier.fillMaxWidth(),
        containerColor = when (kind) {
            PerAppMessageKind.SUCCESS -> MaterialTheme.colorScheme.primaryContainer
            PerAppMessageKind.ERROR -> MaterialTheme.colorScheme.errorContainer
            PerAppMessageKind.INFO -> MaterialTheme.colorScheme.surfaceContainer
        },
    ) {
        VeerStatusBadge(
            status = when (kind) {
                PerAppMessageKind.SUCCESS -> VeerStatus.Connected
                PerAppMessageKind.ERROR -> VeerStatus.Warning
                PerAppMessageKind.INFO -> VeerStatus.Unavailable
            },
            label = stringResource(
                when (kind) {
                    PerAppMessageKind.SUCCESS -> R.string.per_app_message_saved
                    PerAppMessageKind.ERROR -> R.string.per_app_message_error
                    PerAppMessageKind.INFO -> R.string.per_app_message_attention
                },
            ),
        )
        Text(text = message, style = MaterialTheme.typography.bodyMedium)
        VeerSecondaryButton(
            text = stringResource(R.string.common_close),
            onClick = onDismiss,
            modifier = Modifier.align(Alignment.End),
        )
    }
}

@Composable
private fun PerAppSelectionActions(
    selectedCount: Int,
    availableSelectedCount: Int,
    canSelectVisible: Boolean,
    canClear: Boolean,
    onSelectVisible: () -> Unit,
    onClear: () -> Unit,
) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = stringResource(
                R.string.per_app_selection_summary,
                selectedCount,
                availableSelectedCount,
            ),
            style = MaterialTheme.typography.titleMedium,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            VeerSecondaryButton(
                text = stringResource(R.string.per_app_select_visible),
                onClick = onSelectVisible,
                enabled = canSelectVisible,
                modifier = Modifier.weight(1f),
            )
            VeerSecondaryButton(
                text = stringResource(R.string.common_clear),
                onClick = onClear,
                enabled = canClear,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun AppSelectionCard(
    app: InstalledAppEntry,
    selected: Boolean,
    onToggle: () -> Unit,
) {
    val context = LocalContext.current
    val icon = remember(app.packageName, app.isAvailable) {
        if (!app.isAvailable) {
            null
        } else {
            runCatching {
                context.packageManager.getApplicationIcon(app.packageName).toBitmap().asImageBitmap()
            }.getOrNull()
        }
    }
    val canToggle = app.isAvailable || selected

    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("per_app_${app.packageName}"),
        enabled = canToggle,
        onClick = if (canToggle) onToggle else null,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = VeerDimensions.touchTarget),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
        ) {
            if (icon != null) {
                Image(
                    bitmap = icon,
                    contentDescription = null,
                    modifier = Modifier.size(VeerDimensions.appIcon),
                )
            } else {
                Box(
                    modifier = Modifier.size(VeerDimensions.appIcon),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = app.label.firstOrNull()?.uppercase() ?: "?",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs),
            ) {
                Text(text = app.label, style = MaterialTheme.typography.bodyLarge)
                Text(
                    text = app.packageName,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                if (app.isSystemApp || !app.isAvailable) {
                    Row(horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm)) {
                        if (app.isSystemApp) {
                            VeerStatusBadge(
                                status = VeerStatus.Unavailable,
                                label = stringResource(R.string.per_app_system_app),
                            )
                        }
                        if (!app.isAvailable) {
                            VeerStatusBadge(
                                status = VeerStatus.Warning,
                                label = stringResource(R.string.common_unavailable),
                            )
                        }
                    }
                }
            }
            Checkbox(
                checked = selected,
                enabled = canToggle,
                onCheckedChange = { onToggle() },
            )
        }
    }
}

private fun previewPerAppState() = PerAppProxyUiState(
    loading = false,
    mode = PerAppProxyMode.ONLY_SELECTED,
    selectedPackages = setOf("com.example.streaming", "com.example.removed"),
    apps = listOf(
        InstalledAppEntry(
            label = "Streaming application with a deliberately long localized name",
            packageName = "com.example.streaming",
            isSystemApp = false,
        ),
        InstalledAppEntry(
            label = "System browser",
            packageName = "com.example.browser.system",
            isSystemApp = true,
        ),
        InstalledAppEntry(
            label = "com.example.removed",
            packageName = "com.example.removed",
            isSystemApp = false,
            isAvailable = false,
        ),
    ),
)

@VeerThemePreviews
@Composable
private fun PerAppProxyThemePreview() {
    VeerPreview {
        PerAppProxyScreen(
            state = previewPerAppState(),
            runtimeRunning = true,
            onBack = {}, onRetry = {}, onModeChange = {}, onTogglePackage = {},
            onSelectVisible = {}, onClearSelection = {}, onSave = {}, onDismissMessage = {},
        )
    }
}

@VeerResponsivePreviews
@Composable
private fun PerAppProxyResponsivePreview() {
    VeerPreview {
        PerAppProxyScreen(
            state = previewPerAppState(),
            runtimeRunning = false,
            onBack = {}, onRetry = {}, onModeChange = {}, onTogglePackage = {},
            onSelectVisible = {}, onClearSelection = {}, onSave = {}, onDismissMessage = {},
        )
    }
}
