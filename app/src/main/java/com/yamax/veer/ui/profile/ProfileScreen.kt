package com.yamax.veer.ui.profile

import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.R
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.core_profile.SubscriptionRefreshOutcome
import com.yamax.veer.core_profile.internal.parser.PipelineStage
import com.yamax.veer.core_profile.internal.parser.message
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerDialog
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
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.resolve
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal data class ProfileListActions(
    val onBack: () -> Unit,
    val onRefreshAll: () -> Unit,
    val onImportUrl: (String) -> Unit,
    val onPasteUrl: () -> Unit,
    val onSelectFile: () -> Unit,
    val onImportYaml: (String) -> Unit,
    val onClearImportState: () -> Unit,
    val onDismissError: () -> Unit,
    val onActivate: (ProfileId) -> Unit,
    val onDetails: (ProfileId) -> Unit,
    val onDns: (ProfileId) -> Unit,
    val onRefresh: (ProfileId) -> Unit,
    val onEdit: (ProfileId) -> Unit,
    val onDelete: (ProfileId) -> Unit,
    val onDismissEdit: () -> Unit,
    val onUpdateEditName: (String) -> Unit,
    val onSubmitEdit: () -> Unit,
    val onDismissDelete: () -> Unit,
    val onConfirmDelete: () -> Unit,
)

@Composable
internal fun ProfileListScreen(
    onBack: () -> Unit,
    onProfileDetail: (ProfileId) -> Unit,
    onProfileDns: (ProfileId) -> Unit,
    viewModel: ProfileListViewModel = viewModel(),
) {
    val state by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    var urlInput by remember { mutableStateOf("") }
    var yamlInput by remember { mutableStateOf("") }
    val yamlFilePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) viewModel.importDocument(uri)
    }

    ProfileListContent(
        state = state,
        urlInput = urlInput,
        yamlInput = yamlInput,
        onUrlInputChange = { urlInput = it },
        onYamlInputChange = { yamlInput = it },
        actions = ProfileListActions(
            onBack = onBack,
            onRefreshAll = viewModel::refreshAll,
            onImportUrl = viewModel::importUrl,
            onPasteUrl = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.primaryClip
                    ?.takeIf { it.itemCount > 0 }
                    ?.getItemAt(0)
                    ?.coerceToText(context)
                    ?.toString()
                    ?.trim()
                    ?.takeIf(String::isNotEmpty)
                    ?.let { urlInput = it }
            },
            onSelectFile = {
                yamlFilePicker.launch(
                    arrayOf(
                        "application/yaml",
                        "text/yaml",
                        "text/x-yaml",
                        "text/plain",
                        "application/octet-stream",
                    ),
                )
            },
            onImportYaml = viewModel::importYaml,
            onClearImportState = viewModel::clearImportState,
            onDismissError = viewModel::dismissErrorBanner,
            onActivate = viewModel::activate,
            onDetails = onProfileDetail,
            onDns = onProfileDns,
            onRefresh = viewModel::refresh,
            onEdit = viewModel::startEdit,
            onDelete = viewModel::requestDelete,
            onDismissEdit = viewModel::dismissEdit,
            onUpdateEditName = viewModel::updateEditName,
            onSubmitEdit = viewModel::submitEdit,
            onDismissDelete = viewModel::dismissDelete,
            onConfirmDelete = viewModel::confirmDelete,
        ),
    )
}

@Composable
internal fun ProfileListContent(
    state: ProfileListViewModel.UiState,
    urlInput: String,
    yamlInput: String,
    onUrlInputChange: (String) -> Unit,
    onYamlInputChange: (String) -> Unit,
    actions: ProfileListActions,
) {
    val importing = state.importState is ImportState.Running
    val operationInProgress = state.switchingProfileId != null
    val urlInvalid = urlInput.isNotBlank() && !isValidSubscriptionUrl(urlInput)

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.profile_title),
                onBack = actions.onBack,
                backContentDescription = stringResource(R.string.common_back),
                actions = {
                    IconButton(
                        onClick = actions.onRefreshAll,
                        enabled = !state.isRefreshingAll && !operationInProgress,
                    ) {
                        if (state.isRefreshingAll) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(VeerDimensions.iconMedium),
                                strokeWidth = VeerDimensions.progressStroke,
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = stringResource(R.string.profile_refresh_all),
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = VeerSpacing.lg,
                top = padding.calculateTopPadding() + VeerSpacing.md,
                end = VeerSpacing.lg,
                bottom = padding.calculateBottomPadding() + VeerSpacing.xl,
            ),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
        ) {
            state.errorBanner?.let { message ->
                item {
                    ProfileMessagePanel(
                        message = message.resolve(),
                        error = true,
                        onDismiss = actions.onDismissError,
                    )
                }
            }

            state.switchStatus?.let { message ->
                item {
                    Surface(
                        modifier = Modifier.profileContentWidth(),
                        color = MaterialTheme.colorScheme.primaryContainer,
                        shape = VeerShapes.medium,
                    ) {
                        Row(
                            modifier = Modifier.padding(VeerSpacing.md),
                            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (operationInProgress) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(VeerDimensions.iconSmall),
                                    strokeWidth = VeerDimensions.progressStroke,
                                )
                            }
                            Text(message.resolve(), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }

            item {
                SubscriptionImportCard(
                    value = urlInput,
                    invalid = urlInvalid,
                    importing = importing,
                    enabled = !operationInProgress,
                    onValueChange = onUrlInputChange,
                    onPaste = actions.onPasteUrl,
                    onImport = { actions.onImportUrl(urlInput) },
                )
            }

            item {
                YamlImportCard(
                    value = yamlInput,
                    importing = importing,
                    enabled = !operationInProgress,
                    onValueChange = onYamlInputChange,
                    onSelectFile = actions.onSelectFile,
                    onImport = { actions.onImportYaml(yamlInput) },
                )
            }

            if (state.importState !is ImportState.Idle) {
                item {
                    ImportStatusPanel(
                        state = state.importState,
                        onDismiss = actions.onClearImportState,
                    )
                }
            }

            if (state.refreshHistory.isNotEmpty()) {
                item {
                    Text(
                        text = stringResource(R.string.profile_refresh_history),
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.profileContentWidth(),
                    )
                }
                items(state.refreshHistory, key = { it.id }, contentType = { "refresh_record" }) { record ->
                    val status = when (record.outcome) {
                        SubscriptionRefreshOutcome.UPDATED ->
                            stringResource(R.string.profile_refresh_updated)
                        SubscriptionRefreshOutcome.UNCHANGED ->
                            stringResource(R.string.profile_refresh_unchanged)
                        SubscriptionRefreshOutcome.FAILED ->
                            stringResource(R.string.profile_refresh_failed)
                    }
                    val diff = record.diff?.let {
                        stringResource(
                            R.string.profile_refresh_diff,
                            it.proxiesAdded,
                            it.proxiesRemoved,
                            it.groupsAdded,
                            it.groupsRemoved,
                            it.rulesAdded,
                            it.rulesRemoved,
                        )
                    }.orEmpty()
                    VeerCard(modifier = Modifier.profileContentWidth()) {
                        Text(
                            text = stringResource(
                                R.string.profile_refresh_record,
                                record.displayName,
                                status,
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Text(
                            text = SimpleDateFormat(
                                "yyyy-MM-dd HH:mm",
                                Locale.getDefault(),
                            ).format(Date(record.completedAtMs)) + diff,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        record.error?.let {
                            Text(
                                text = it,
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
            }

            item {
                Column(
                    modifier = Modifier.profileContentWidth(),
                    verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
                ) {
                    HorizontalDivider()
                    Text(
                        text = if (state.profiles.isEmpty()) {
                            stringResource(R.string.profile_saved)
                        } else {
                            stringResource(R.string.profile_saved_count, state.profiles.size)
                        },
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            }

            if (state.profiles.isEmpty()) {
                item {
                    VeerStateView(
                        title = stringResource(R.string.profile_empty),
                        description = stringResource(R.string.profile_subscription_description),
                        modifier = Modifier.profileContentWidth(),
                    )
                }
            } else {
                items(state.profiles, key = { it.id.value }, contentType = { "profile" }) { profile ->
                    ProfileCard(
                        meta = profile,
                        isActive = state.activeProfileId == profile.id,
                        isRefreshing = profile.id.value in state.refreshingIds,
                        runtimeStopped = state.runtimeStopped,
                        profileSwitchAllowed = state.profileSwitchAllowed,
                        operationInProgress = operationInProgress,
                        isSwitching = state.switchingProfileId == profile.id,
                        onActivate = { actions.onActivate(profile.id) },
                        onDetails = { actions.onDetails(profile.id) },
                        onDns = { actions.onDns(profile.id) },
                        onRefresh = { actions.onRefresh(profile.id) },
                        onEdit = { actions.onEdit(profile.id) },
                        onDelete = { actions.onDelete(profile.id) },
                        modifier = Modifier.profileContentWidth(),
                    )
                }
            }
        }
    }

    state.editDialog?.let { dialog ->
        RenameProfileDialog(
            name = dialog.editedName,
            onNameChange = actions.onUpdateEditName,
            onConfirm = actions.onSubmitEdit,
            onDismiss = actions.onDismissEdit,
        )
    }

    state.deleteTarget?.let { id ->
        val name = state.profiles.find { it.id == id }?.displayName ?: id.value
        VeerDialog(
            title = stringResource(R.string.profile_delete_title, name),
            body = stringResource(R.string.profile_delete_body),
            confirmText = stringResource(R.string.common_delete),
            onConfirm = actions.onConfirmDelete,
            dismissText = stringResource(R.string.common_cancel),
            onDismiss = actions.onDismissDelete,
        )
    }
}

private fun Modifier.profileContentWidth(): Modifier =
    fillMaxWidth().widthIn(max = VeerDimensions.contentMaxWidth)

@Composable
private fun SubscriptionImportCard(
    value: String,
    invalid: Boolean,
    importing: Boolean,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
    onPaste: () -> Unit,
    onImport: () -> Unit,
) {
    VeerCard(modifier = Modifier.profileContentWidth()) {
        Text(
            text = stringResource(R.string.profile_subscription_url),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            text = stringResource(R.string.profile_subscription_description),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
        VeerTextField(
            value = value,
            onValueChange = onValueChange,
            label = stringResource(R.string.profile_subscription_url_label),
            placeholder = stringResource(R.string.profile_subscription_url_placeholder),
            errorText = if (invalid) {
                stringResource(R.string.profile_subscription_url_invalid)
            } else null,
            enabled = enabled && !importing,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        VeerSecondaryButton(
            text = stringResource(R.string.profile_paste_subscription_url),
            onClick = onPaste,
            enabled = enabled && !importing,
            modifier = Modifier.fillMaxWidth(),
        )
        VeerPrimaryButton(
            text = stringResource(
                if (importing) R.string.profile_importing
                else R.string.profile_import_subscription,
            ),
            onClick = onImport,
            enabled = value.isNotBlank() && !invalid && enabled && !importing,
            loading = importing,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun YamlImportCard(
    value: String,
    importing: Boolean,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
    onSelectFile: () -> Unit,
    onImport: () -> Unit,
) {
    VeerCard(modifier = Modifier.profileContentWidth()) {
        Text(
            text = stringResource(R.string.profile_local_yaml),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            text = stringResource(R.string.profile_yaml_description),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
        VeerSecondaryButton(
            text = stringResource(R.string.profile_select_yaml),
            onClick = onSelectFile,
            enabled = enabled && !importing,
            modifier = Modifier.fillMaxWidth(),
        )
        VeerTextField(
            value = value,
            onValueChange = onValueChange,
            label = stringResource(R.string.profile_yaml_label),
            placeholder = stringResource(R.string.profile_yaml_placeholder),
            enabled = enabled && !importing,
            minLines = 4,
            maxLines = 12,
            modifier = Modifier.fillMaxWidth(),
        )
        VeerSecondaryButton(
            text = stringResource(
                if (importing) R.string.profile_importing
                else R.string.profile_import_pasted,
            ),
            onClick = onImport,
            enabled = value.isNotBlank() && enabled && !importing,
            loading = importing,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun ProfileMessagePanel(
    message: String,
    error: Boolean,
    onDismiss: () -> Unit,
) {
    Surface(
        modifier = Modifier.profileContentWidth(),
        color = if (error) MaterialTheme.colorScheme.errorContainer
        else MaterialTheme.colorScheme.secondaryContainer,
        shape = VeerShapes.medium,
    ) {
        Row(
            modifier = Modifier.padding(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = message,
                color = if (error) MaterialTheme.colorScheme.onErrorContainer
                else MaterialTheme.colorScheme.onSecondaryContainer,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.common_close))
            }
        }
    }
}

@Composable
private fun ImportStatusPanel(state: ImportState, onDismiss: () -> Unit) {
    VeerCard(modifier = Modifier.profileContentWidth()) {
        when (state) {
            is ImportState.Idle -> Unit
            is ImportState.Running -> VeerStatusBadge(
                status = VeerStatus.Loading,
                label = stringResource(
                    if (state.stage == PipelineStage.PERSIST) R.string.profile_import_saving
                    else R.string.profile_import_starting,
                ),
            )
            is ImportState.Success -> {
                VeerStatusBadge(
                    status = VeerStatus.Connected,
                    label = stringResource(R.string.profile_import_success, state.profileName),
                )
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.common_close))
                }
            }
            is ImportState.Failure -> {
                VeerStatusBadge(
                    status = VeerStatus.Warning,
                    label = stringResource(R.string.profile_import_failure),
                )
                state.errors.forEach { error ->
                    Text(
                        text = stringResource(R.string.profile_import_error_bullet, error.message()),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.common_close))
                }
            }
        }
    }
}

@Composable
private fun RenameProfileDialog(
    name: String,
    onNameChange: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.profile_rename_title)) },
        text = {
            VeerTextField(
                value = name,
                onValueChange = onNameChange,
                label = stringResource(R.string.profile_name),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = name.isNotBlank()) {
                Text(stringResource(R.string.common_save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.common_cancel))
            }
        },
        shape = VeerShapes.extraLarge,
    )
}

@Composable
private fun ProfileCard(
    meta: ProfileMetadata,
    isActive: Boolean,
    isRefreshing: Boolean,
    runtimeStopped: Boolean,
    profileSwitchAllowed: Boolean,
    operationInProgress: Boolean,
    isSwitching: Boolean,
    onActivate: () -> Unit,
    onDetails: () -> Unit,
    onDns: () -> Unit,
    onRefresh: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val dateFormat = remember { SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()) }
    val isUrlSource = meta.source is ProfileSource.SubscriptionUrl

    VeerCard(
        modifier = modifier,
        containerColor = if (isActive) MaterialTheme.colorScheme.secondaryContainer
        else MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = meta.displayName,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (isActive) {
                VeerStatusBadge(
                    status = VeerStatus.Connected,
                    label = stringResource(R.string.profile_current),
                )
            }
            IconButton(onClick = onEdit, modifier = Modifier.size(VeerDimensions.touchTarget)) {
                Icon(
                    imageVector = Icons.Default.Edit,
                    contentDescription = stringResource(R.string.profile_rename_description),
                )
            }
        }

        Text(
            text = profileSourceLabel(meta.source),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = stringResource(
                R.string.profile_stats,
                meta.proxyCount,
                meta.groupCount,
                meta.ruleCount,
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            text = stringResource(
                R.string.profile_updated_at,
                dateFormat.format(Date(meta.lastUpdatedMs)),
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
        meta.subscriptionUsage?.let { usage ->
            if (usage.totalBytes > 0) {
                Text(
                    text = stringResource(
                        R.string.profile_traffic,
                        formatBytes(usage.usedBytes),
                        formatBytes(usage.totalBytes),
                        formatBytes(usage.remainingBytes),
                    ),
                    color = if (usage.remainingBytes == 0L) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            usage.expireAtMs?.let { expiresAt ->
                Text(
                    text = stringResource(
                        R.string.profile_expires,
                        dateFormat.format(Date(expiresAt)),
                    ),
                    color = if (expiresAt <= System.currentTimeMillis()) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        if (!isActive) {
            VeerPrimaryButton(
                text = stringResource(
                    if (isSwitching) R.string.profile_switching else R.string.profile_activate,
                ),
                onClick = onActivate,
                enabled = profileSwitchAllowed && !operationInProgress,
                loading = isSwitching,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            VeerSecondaryButton(
                text = stringResource(R.string.profile_details),
                onClick = onDetails,
                modifier = Modifier.weight(1f),
            )
            VeerSecondaryButton(
                text = stringResource(R.string.settings_dns),
                onClick = onDns,
                modifier = Modifier.weight(1f),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            if (isUrlSource) {
                VeerSecondaryButton(
                    text = stringResource(R.string.profile_refresh_subscription),
                    onClick = onRefresh,
                    enabled = !operationInProgress && !isRefreshing && (runtimeStopped || !isActive),
                    loading = isRefreshing,
                    modifier = Modifier.weight(1f),
                )
            }
            VeerSecondaryButton(
                text = stringResource(R.string.common_delete),
                onClick = onDelete,
                enabled = !operationInProgress && (runtimeStopped || !isActive),
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun profileSourceLabel(source: ProfileSource): String = when (source) {
    is ProfileSource.SubscriptionUrl -> stringResource(
        R.string.profile_source_subscription,
        runCatching { URI(source.url).host }
            .getOrNull()
            .orEmpty()
            .ifBlank { stringResource(R.string.profile_source_https_url) },
    )
    is ProfileSource.ClashFile -> stringResource(
        R.string.profile_source_file,
        source.originalFileName,
    )
    is ProfileSource.Base64Text -> stringResource(R.string.profile_source_base64)
}

private fun isValidSubscriptionUrl(value: String): Boolean = runCatching {
    val uri = URI(value.trim())
    uri.scheme?.lowercase(Locale.ROOT) in setOf("http", "https") && !uri.host.isNullOrBlank()
}.getOrDefault(false)

private fun formatBytes(bytes: Long): String {
    if (bytes < 1_024) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB", "PB")
    var value = bytes.toDouble()
    var unit = -1
    while (value >= 1_024 && unit < units.lastIndex) {
        value /= 1_024
        unit += 1
    }
    return String.format(Locale.US, "%.1f %s", value, units[unit])
}

private val NoOpProfileActions = ProfileListActions(
    onBack = {}, onRefreshAll = {}, onImportUrl = {}, onPasteUrl = {}, onSelectFile = {},
    onImportYaml = {}, onClearImportState = {}, onDismissError = {},
    onActivate = {}, onDetails = {}, onDns = {}, onRefresh = {}, onEdit = {},
    onDelete = {}, onDismissEdit = {}, onUpdateEditName = {}, onSubmitEdit = {},
    onDismissDelete = {}, onConfirmDelete = {},
)

@VeerThemePreviews
@Composable
private fun ProfileListPreview() {
    ProfilePreviewContent()
}

@VeerResponsivePreviews
@Composable
private fun ProfileListResponsivePreview() {
    ProfilePreviewContent(
        profileName = "Work, streaming, AI and international research subscription with a long name",
    )
}

@Composable
private fun ProfilePreviewContent(profileName: String = "Daily subscription") {
    val profile = ProfileMetadata(
        id = ProfileId("preview-profile"),
        displayName = profileName,
        source = ProfileSource.SubscriptionUrl(
            url = "https://example.com/subscription",
            lastFetchedMs = 1_700_000_000_000,
        ),
        importedAtMs = 1_700_000_000_000,
        lastUpdatedMs = 1_700_000_000_000,
        proxyCount = 18,
        groupCount = 6,
        ruleCount = 520,
        rawSizeBytes = 32_768,
        configHashSha256 = "preview",
    )
    VeerPreview {
        ProfileListContent(
            state = ProfileListViewModel.UiState(
                profiles = listOf(profile),
                activeProfileId = profile.id,
                importState = ImportState.Idle,
            ),
            urlInput = "",
            yamlInput = "",
            onUrlInputChange = {},
            onYamlInputChange = {},
            actions = NoOpProfileActions,
        )
    }
}

@VeerThemePreviews
@Composable
private fun ProfileImportRunningPreview() {
    VeerPreview {
        ProfileListContent(
            state = ProfileListViewModel.UiState(
                importState = ImportState.Running(PipelineStage.FETCH, "Fetching"),
            ),
            urlInput = "https://example.com/subscription",
            yamlInput = "",
            onUrlInputChange = {},
            onYamlInputChange = {},
            actions = NoOpProfileActions,
        )
    }
}

@VeerThemePreviews
@Composable
private fun ProfileErrorPreview() {
    VeerPreview {
        ProfileListContent(
            state = ProfileListViewModel.UiState(
                errorBanner = com.yamax.veer.ui.uiText(
                    R.string.profile_subscription_import_failed,
                    "Network unavailable",
                ),
            ),
            urlInput = "not-a-url",
            yamlInput = "",
            onUrlInputChange = {},
            onYamlInputChange = {},
            actions = NoOpProfileActions,
        )
    }
}
