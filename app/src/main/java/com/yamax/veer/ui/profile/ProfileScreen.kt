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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.core_profile.internal.parser.message
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun ProfileListScreen(
    onProfileDetail: (ProfileId) -> Unit,
    viewModel: ProfileListViewModel = viewModel(),
) {
    val state by viewModel.uiState.collectAsState()
    val importing = state.importState is ImportState.Running

    var urlInput  by remember { mutableStateOf("") }
    var yamlInput by remember { mutableStateOf("") }

    Scaffold(
        topBar = {
            TopAppBar(
                title   = { Text("Profiles") },
                actions = {
                    IconButton(
                        onClick  = { viewModel.refreshAll() },
                        enabled  = !state.isRefreshingAll,
                    ) {
                        if (state.isRefreshingAll) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh all subscriptions")
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
                                    text     = msg,
                                    style    = MaterialTheme.typography.bodySmall,
                                    color    = MaterialTheme.colorScheme.onErrorContainer,
                                    modifier = Modifier.weight(1f),
                                )
                                TextButton(onClick = { viewModel.dismissErrorBanner() }) {
                                    Text("Dismiss")
                                }
                            }
                        }
                    }
                }

                // Subscription URL input
                item { Text("Subscription URL", style = MaterialTheme.typography.titleSmall) }
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
                        onClick  = { viewModel.importUrl(urlInput); urlInput = "" },
                        enabled  = urlInput.isNotBlank() && !importing,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Import URL") }
                }

                // Paste YAML input
                item {
                    Spacer(Modifier.height(2.dp))
                    Text("Paste Clash YAML", style = MaterialTheme.typography.titleSmall)
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
                        onClick  = { viewModel.importYaml(yamlInput); yamlInput = "" },
                        enabled  = yamlInput.isNotBlank() && !importing,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Import YAML") }
                }

                // Import status row
                item {
                    ImportStatusRow(
                        state    = state.importState,
                        onDismiss = { viewModel.clearImportState() },
                    )
                }

                // Profile list header
                item {
                    Spacer(Modifier.height(4.dp))
                    HorizontalDivider()
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text  = if (state.profiles.isEmpty()) "Saved Profiles"
                                else "Saved Profiles (${state.profiles.size})",
                        style = MaterialTheme.typography.titleSmall,
                    )
                }

                if (state.profiles.isEmpty()) {
                    item {
                        Text(
                            text  = "No profiles yet.",
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
                            onActivate   = { viewModel.activate(meta.id) },
                            onDetails    = { onProfileDetail(meta.id) },
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
            title            = { Text("Rename Profile") },
            text             = {
                OutlinedTextField(
                    value         = dialog.editedName,
                    onValueChange = { viewModel.updateEditName(it) },
                    label         = { Text("Name") },
                    singleLine    = true,
                    modifier      = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick  = { viewModel.submitEdit() },
                    enabled  = dialog.editedName.isNotBlank(),
                ) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.dismissEdit() }) { Text("Cancel") }
            },
        )
    }

    // Delete confirmation dialog
    state.deleteTarget?.let { id ->
        val name = state.profiles.find { it.id == id }?.displayName ?: id.value
        AlertDialog(
            onDismissRequest = { viewModel.dismissDelete() },
            title            = { Text("Delete \"$name\"?") },
            text             = { Text("This profile will be permanently removed.") },
            confirmButton    = {
                TextButton(onClick = { viewModel.confirmDelete() }) { Text("Delete") }
            },
            dismissButton    = {
                TextButton(onClick = { viewModel.dismissDelete() }) { Text("Cancel") }
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
            Text(state.message, style = MaterialTheme.typography.bodySmall)
        }

        is ImportState.Success -> Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment     = Alignment.CenterVertically,
        ) {
            Text(
                text  = "✓ Imported \"${state.profileName}\"",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
            TextButton(onClick = onDismiss) { Text("Dismiss") }
        }

        is ImportState.Failure -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                modifier              = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                Text(
                    text  = "Import failed:",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
                TextButton(onClick = onDismiss) { Text("Dismiss") }
            }
            state.errors.forEach { err ->
                Text(
                    text  = "• ${err.message()}",
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
    onActivate: () -> Unit,
    onDetails: () -> Unit,
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
                            text  = "ACTIVE",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        Spacer(Modifier.width(4.dp))
                    }
                    IconButton(onClick = onEdit, modifier = Modifier.size(28.dp)) {
                        Icon(
                            imageVector        = Icons.Default.Edit,
                            contentDescription = "Rename",
                            modifier           = Modifier.size(16.dp),
                        )
                    }
                }
            }

            // Source info
            when (val src = meta.source) {
                is ProfileSource.SubscriptionUrl -> Text(
                    text     = src.url,
                    style    = MaterialTheme.typography.bodySmall,
                    color    = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                is ProfileSource.ClashFile -> Text(
                    text  = "File: ${src.originalFileName}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                is ProfileSource.Base64Text -> Text(
                    text  = "Base64 import",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            // Stats
            Text(
                text  = "${meta.proxyCount} proxies · ${meta.groupCount} groups · ${meta.ruleCount} rules",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text  = "Updated: ${dateFmt.format(Date(meta.lastUpdatedMs))}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(4.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                if (!isActive) {
                    Button(
                        onClick  = onActivate,
                        modifier = Modifier.weight(1f),
                    ) { Text("Activate") }
                }
                OutlinedButton(
                    onClick  = onDetails,
                    modifier = if (isActive) Modifier.weight(1f) else Modifier,
                ) { Text("Details") }
                if (isUrlSource) {
                    IconButton(
                        onClick  = onRefresh,
                        enabled  = !isRefreshing,
                        modifier = Modifier.size(36.dp),
                    ) {
                        if (isRefreshing) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh subscription")
                        }
                    }
                }
                OutlinedButton(onClick = onDelete) { Text("Delete") }
            }
        }
    }
}
