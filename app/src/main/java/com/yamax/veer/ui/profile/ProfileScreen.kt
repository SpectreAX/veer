@file:OptIn(ExperimentalMaterial3Api::class)

package com.yamax.veer.ui.profile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.R
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.core_profile.SubscriptionRefreshOutcome
import com.yamax.veer.core_profile.internal.parser.PipelineStage
import com.yamax.veer.core_profile.internal.parser.message
import com.yamax.veer.ui.resolve
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun ProfileListScreen(
    onProfileDetail: (ProfileId) -> Unit,
    onProfileDns: (ProfileId) -> Unit,
    viewModel: ProfileListViewModel = viewModel(),
) {
    val state by viewModel.uiState.collectAsState()
    val importing = state.importState is ImportState.Running
    val profileOperationInProgress = state.switchingProfileId != null

    var urlInput  by remember { mutableStateOf("") }
    var yamlInput by remember { mutableStateOf("") }
    val yamlFilePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) viewModel.importDocument(uri)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.profile_title)) },
                actions = {
                    IconButton(
                        onClick  = { viewModel.refreshAll() },
                        enabled  = !state.isRefreshingAll && !profileOperationInProgress,
                    ) {
                        if (state.isRefreshingAll) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(
                                Icons.Default.Refresh,
                                contentDescription = stringResource(R.string.profile_refresh_all),
                            )
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
        ) {
            LazyColumn(
                contentPadding      = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier            = Modifier.fillMaxSize(),
            ) {

                // Error banner
                state.errorBanner?.let { msg ->
                    item {
                        Card(
                            colors   = CardDefaults.cardColors(
                                containerColor = MaterialTheme.colorScheme.errorContainer,
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier              = Modifier
                                    .padding(12.dp)
                                    .fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment     = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = msg.resolve(),
                                    style    = MaterialTheme.typography.bodySmall,
                                    color    = MaterialTheme.colorScheme.onErrorContainer,
                                    modifier = Modifier.weight(1f),
                                )
                                TextButton(onClick = { viewModel.dismissErrorBanner() }) {
                                    Text(stringResource(R.string.common_close))
                                }
                            }
                        }
                    }
                }

                state.switchStatus?.let { msg ->
                    item {
                        Card(
                            colors = CardDefaults.cardColors(
                                containerColor = MaterialTheme.colorScheme.primaryContainer,
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier
                                    .padding(12.dp)
                                    .fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (profileOperationInProgress) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(18.dp),
                                        strokeWidth = 2.dp,
                                    )
                                }
                                Text(
                                    text = msg.resolve(),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                                )
                            }
                        }
                    }
                }

                // Subscription URL input
                item {
                    Text(
                        stringResource(R.string.profile_subscription_url),
                        style = MaterialTheme.typography.titleSmall,
                    )
                }
                item {
                    OutlinedTextField(
                        value         = urlInput,
                        onValueChange = { urlInput = it },
                        label         = { Text("URL") },
                        placeholder   = { Text("https://…") },
                        singleLine    = true,
                        modifier      = Modifier.fillMaxWidth(),
                    )
                }
                item {
                    Button(
                        onClick  = { viewModel.importUrl(urlInput) },
                        enabled  = urlInput.isNotBlank() && !importing && !profileOperationInProgress,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            stringResource(
                                if (importing) R.string.profile_importing
                                else R.string.profile_import_subscription,
                            ),
                        )
                    }
                }

                // Paste YAML input
                item {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        stringResource(R.string.profile_local_yaml),
                        style = MaterialTheme.typography.titleSmall,
                    )
                }
                item {
                    OutlinedButton(
                        onClick = {
                            yamlFilePicker.launch(
                                arrayOf(
                                    "application/yaml",
                                    "text/yaml",
                                    "text/x-yaml",
                                    "text/plain",
                                    "application/octet-stream",
                                )
                            )
                        },
                        enabled = !importing && !profileOperationInProgress,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(stringResource(R.string.profile_select_yaml)) }
                }
                item {
                    OutlinedTextField(
                        value         = yamlInput,
                        onValueChange = { yamlInput = it },
                        label         = { Text("Clash YAML") },
                        placeholder   = { Text("proxies:\n  - name: my-proxy\n    …") },
                        minLines      = 4,
                        maxLines      = 12,
                        modifier      = Modifier.fillMaxWidth(),
                    )
                }
                item {
                    Button(
                        onClick  = { viewModel.importYaml(yamlInput) },
                        enabled  = yamlInput.isNotBlank() && !importing && !profileOperationInProgress,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            stringResource(
                                if (importing) R.string.profile_importing
                                else R.string.profile_import_pasted,
                            ),
                        )
                    }
                }

                // Import status row
                item {
                    ImportStatusRow(
                        state    = state.importState,
                        onDismiss = { viewModel.clearImportState() },
                    )
                }

                if (state.refreshHistory.isNotEmpty()) {
                    item {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            stringResource(R.string.profile_refresh_history),
                            style = MaterialTheme.typography.titleSmall,
                        )
                    }
                    items(state.refreshHistory, key = { it.id }) { record ->
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
                        Card(modifier = Modifier.fillMaxWidth()) {
                            Column(
                                modifier = Modifier.padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(3.dp),
                            ) {
                                Text(
                                    stringResource(
                                        R.string.profile_refresh_record,
                                        record.displayName,
                                        status,
                                    ),
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                Text(
                                    SimpleDateFormat(
                                        "yyyy-MM-dd HH:mm",
                                        Locale.getDefault(),
                                    ).format(Date(record.completedAtMs)) + diff,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                record.error?.let {
                                    Text(
                                        it,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.error,
                                    )
                                }
                            }
                        }
                    }
                }

                // Profile list header
                item {
                    Spacer(Modifier.height(4.dp))
                    HorizontalDivider()
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = if (state.profiles.isEmpty()) {
                            stringResource(R.string.profile_saved)
                        } else {
                            stringResource(R.string.profile_saved_count, state.profiles.size)
                        },
                        style = MaterialTheme.typography.titleSmall,
                    )
                }

                if (state.profiles.isEmpty()) {
                    item {
                        Text(
                            text = stringResource(R.string.profile_empty),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    items(state.profiles, key = { it.id.value }) { meta ->
                        ProfileCard(
                            meta         = meta,
                            isActive     = state.activeProfileId == meta.id,
                            isRefreshing = meta.id.value in state.refreshingIds,
                            runtimeStopped = state.runtimeStopped,
                            profileSwitchAllowed = state.profileSwitchAllowed,
                            operationInProgress = profileOperationInProgress,
                            isSwitching = state.switchingProfileId == meta.id,
                            onActivate   = { viewModel.activate(meta.id) },
                            onDetails    = { onProfileDetail(meta.id) },
                            onDns        = { onProfileDns(meta.id) },
                            onRefresh    = { viewModel.refresh(meta.id) },
                            onEdit       = { viewModel.startEdit(meta.id) },
                            onDelete     = { viewModel.requestDelete(meta.id) },
                        )
                    }
                }
            }
        }
    }

    // Rename dialog
    state.editDialog?.let { dialog ->
        AlertDialog(
            onDismissRequest = { viewModel.dismissEdit() },
            title = { Text(stringResource(R.string.profile_rename_title)) },
            text             = {
                OutlinedTextField(
                    value         = dialog.editedName,
                    onValueChange = { viewModel.updateEditName(it) },
                    label = { Text(stringResource(R.string.profile_name)) },
                    singleLine    = true,
                    modifier      = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick  = { viewModel.submitEdit() },
                    enabled  = dialog.editedName.isNotBlank(),
                ) { Text(stringResource(R.string.common_save)) }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.dismissEdit() }) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    // Delete confirmation dialog
    state.deleteTarget?.let { id ->
        val name = state.profiles.find { it.id == id }?.displayName ?: id.value
        AlertDialog(
            onDismissRequest = { viewModel.dismissDelete() },
            title = { Text(stringResource(R.string.profile_delete_title, name)) },
            text = { Text(stringResource(R.string.profile_delete_body)) },
            confirmButton    = {
                TextButton(onClick = { viewModel.confirmDelete() }) {
                    Text(stringResource(R.string.common_delete))
                }
            },
            dismissButton    = {
                TextButton(onClick = { viewModel.dismissDelete() }) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }
}

// ── Import status ─────────────────────────────────────────────────────────────

@Composable
private fun ImportStatusRow(state: ImportState, onDismiss: () -> Unit) {
    when (state) {
        is ImportState.Idle -> Unit

        is ImportState.Running -> Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            Text(
                stringResource(
                    when (state.stage) {
                        PipelineStage.PERSIST -> R.string.profile_import_saving
                        else -> R.string.profile_import_starting
                    },
                ),
                style = MaterialTheme.typography.bodySmall,
            )
        }

        is ImportState.Success -> Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment     = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.profile_import_success, state.profileName),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_close)) }
        }

        is ImportState.Failure -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                modifier              = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.profile_import_failure),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_close)) }
            }
            state.errors.forEach { err ->
                Text(
                    text = stringResource(R.string.profile_import_error_bullet, err.message()),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

// ── Profile card ──────────────────────────────────────────────────────────────

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
) {
    val dateFmt = remember { SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()) }
    val isUrlSource = meta.source is ProfileSource.SubscriptionUrl

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors   = if (isActive) CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
        ) else CardDefaults.cardColors(),
    ) {
        Column(
            modifier            = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // Name + active badge + edit icon
            Row(
                modifier              = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                Text(
                    text     = meta.displayName,
                    style    = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f),
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    if (isActive) {
                        Text(
                            text = stringResource(R.string.profile_current),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        Spacer(Modifier.width(4.dp))
                    }
                    IconButton(onClick = onEdit, modifier = Modifier.size(28.dp)) {
                        Icon(
                            imageVector        = Icons.Default.Edit,
                            contentDescription = stringResource(R.string.profile_rename_description),
                            modifier           = Modifier.size(16.dp),
                        )
                    }
                }
            }

            // Source info
            when (val src = meta.source) {
                is ProfileSource.SubscriptionUrl -> Text(
                    text = stringResource(
                        R.string.profile_source_subscription,
                        runCatching { java.net.URI(src.url).host }
                            .getOrNull()
                            .orEmpty()
                            .ifBlank { "HTTPS URL" },
                    ),
                    style    = MaterialTheme.typography.bodySmall,
                    color    = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                is ProfileSource.ClashFile -> Text(
                    text = stringResource(R.string.profile_source_file, src.originalFileName),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                is ProfileSource.Base64Text -> Text(
                    text = stringResource(R.string.profile_source_base64),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            // Stats
            Text(
                text = stringResource(
                    R.string.profile_stats,
                    meta.proxyCount,
                    meta.groupCount,
                    meta.ruleCount,
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = stringResource(
                    R.string.profile_updated_at,
                    dateFmt.format(Date(meta.lastUpdatedMs)),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
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
                        style = MaterialTheme.typography.bodySmall,
                        color = if (usage.remainingBytes == 0L) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
                usage.expireAtMs?.let { expireAt ->
                    Text(
                        text = stringResource(
                            R.string.profile_expires,
                            dateFmt.format(Date(expireAt)),
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (expireAt <= System.currentTimeMillis()) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
            }

            Spacer(Modifier.height(4.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                if (!isActive) {
                    Button(
                        onClick  = onActivate,
                        enabled  = profileSwitchAllowed && !operationInProgress,
                        modifier = Modifier.weight(1f),
                    ) {
                        if (isSwitching) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                            )
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(
                            stringResource(
                                if (isSwitching) R.string.profile_switching
                                else R.string.profile_activate,
                            ),
                        )
                    }
                }
                OutlinedButton(
                    onClick  = onDetails,
                    modifier = if (isActive) Modifier.weight(1f) else Modifier,
                ) { Text(stringResource(R.string.profile_details)) }
                OutlinedButton(onClick = onDns) { Text("DNS") }
                if (isUrlSource) {
                    IconButton(
                        onClick  = onRefresh,
                        enabled  = !operationInProgress &&
                            !isRefreshing &&
                            (runtimeStopped || !isActive),
                        modifier = Modifier.size(36.dp),
                    ) {
                        if (isRefreshing) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(
                                Icons.Default.Refresh,
                                contentDescription = stringResource(
                                    R.string.profile_refresh_subscription,
                                ),
                            )
                        }
                    }
                }
                OutlinedButton(
                    onClick = onDelete,
                    enabled = !operationInProgress && (runtimeStopped || !isActive),
                ) { Text(stringResource(R.string.common_delete)) }
            }
        }
    }
}

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
