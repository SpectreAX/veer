package com.yamax.veer.ui.rules

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.data.AiRuleHealth
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.theme.VeerTheme

class RulesActivity : ComponentActivity() {
    private val viewModel: RulesViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                val appState by AppStateRepository.appState.collectAsStateWithLifecycle()
                val activeProfileId = appState.profile.activeProfileId?.value
                val engineRunning = appState.runtime.engineState is EngineState.Running
                LaunchedEffect(activeProfileId, engineRunning) {
                    viewModel.refresh()
                }
                RulesScreen(
                    state = state.copy(
                        profileName = appState.profile.activeMetadata?.displayName
                            ?: activeProfileId
                            ?: state.profileName,
                        profileId = activeProfileId,
                        engineRunning = engineRunning,
                    ),
                    onBack = ::finish,
                    onRefresh = viewModel::refresh,
                    onReapply = viewModel::reapply,
                    onEnabledChange = viewModel::setEnabled,
                    onDelete = viewModel::delete,
                    onRebind = viewModel::rebind,
                    onDismissMessage = viewModel::clearMessage,
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
internal fun RulesScreen(
    state: RulesUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onReapply: () -> Unit,
    onEnabledChange: (String, Boolean) -> Unit,
    onDelete: (String) -> Unit,
    onRebind: (String, String) -> Unit,
    onDismissMessage: () -> Unit,
) {
    var rebindRule by remember { mutableStateOf<ManagedAiRule?>(null) }
    var deleteRule by remember { mutableStateOf<ManagedAiRule?>(null) }

    Scaffold(modifier = Modifier.fillMaxSize()) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TextButton(onClick = onBack) { Text(stringResource(R.string.common_back)) }
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.rules_title), style = MaterialTheme.typography.headlineSmall)
                    Text(
                        state.profileName ?: stringResource(R.string.rules_no_active_profile_name),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                OutlinedButton(onClick = onRefresh, enabled = !state.loading) {
                    Text(stringResource(R.string.common_refresh))
                }
                Button(onClick = onReapply, enabled = !state.loading) {
                    Text(stringResource(R.string.rules_reapply))
                }
            }

            state.message?.let { message ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(
                            MaterialTheme.colorScheme.secondaryContainer,
                            RoundedCornerShape(12.dp),
                        )
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(message.resolve(), modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismissMessage) {
                        Text(stringResource(R.string.common_close))
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            if (state.loading && state.rules.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else if (state.profileId == null) {
                EmptyRules(stringResource(R.string.rules_activate_profile_first))
            } else if (state.rules.isEmpty()) {
                EmptyRules(stringResource(R.string.rules_empty))
            } else {
                Text(
                    stringResource(
                        R.string.rules_count_status,
                        state.rules.size,
                        stringResource(
                            if (state.engineRunning) R.string.rules_runtime_connected
                            else R.string.rules_runtime_disconnected,
                        ),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 6.dp),
                )
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag("ai_rule_list"),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    items(state.rules, key = ManagedAiRule::id) { rule ->
                        RuleCard(
                            rule = rule,
                            state = state,
                            onEnabledChange = { onEnabledChange(rule.id, it) },
                            onRebind = { rebindRule = rule },
                            onDelete = { deleteRule = rule },
                        )
                    }
                    item { Spacer(Modifier.height(16.dp)) }
                }
            }
        }
    }

    rebindRule?.let { rule ->
        PolicyPickerDialog(
            current = rule.policy,
            policies = state.availablePolicies,
            onDismiss = { rebindRule = null },
            onSelect = { policy ->
                rebindRule = null
                onRebind(rule.id, policy)
            },
        )
    }

    deleteRule?.let { rule ->
        val presentation = aiRulePresentation(rule)
        AlertDialog(
            onDismissRequest = { deleteRule = null },
            title = { Text(stringResource(R.string.rules_delete_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.rules_delete_body,
                        presentation.routeSummary.resolve(),
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteRule = null
                        onDelete(rule.id)
                    },
                ) { Text(stringResource(R.string.common_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { deleteRule = null }) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }
}

@Composable
private fun RuleCard(
    rule: ManagedAiRule,
    state: RulesUiState,
    onEnabledChange: (Boolean) -> Unit,
    onRebind: () -> Unit,
    onDelete: () -> Unit,
) {
    val presentation = aiRulePresentation(rule)
    val unavailable = rule.policy in state.unavailablePolicies
    val (healthText, healthColor) = when {
        !rule.enabled -> stringResource(R.string.rules_health_disabled) to
            MaterialTheme.colorScheme.onSurfaceVariant
        !rule.policyAvailable -> stringResource(R.string.rules_health_policy_missing) to
            MaterialTheme.colorScheme.error
        unavailable -> stringResource(R.string.rules_health_node_unavailable) to
            MaterialTheme.colorScheme.error
        !state.engineRunning || rule.health == AiRuleHealth.NOT_LOADED ->
            stringResource(R.string.rules_health_not_loaded) to MaterialTheme.colorScheme.tertiary
        else -> stringResource(R.string.rules_health_running) to MaterialTheme.colorScheme.primary
    }
    val busy = state.busyRuleId == rule.id

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("ai_rule_${rule.id}")
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
            .border(
                1.dp,
                MaterialTheme.colorScheme.outlineVariant,
                RoundedCornerShape(16.dp),
            )
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    presentation.routeSummary.resolve(),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.testTag("ai_rule_route_${rule.id}"),
                )
                Text(
                    presentation.matchDescription.resolve(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(healthText, color = healthColor, style = MaterialTheme.typography.labelLarge)
            Switch(
                checked = rule.enabled,
                onCheckedChange = onEnabledChange,
                enabled = !busy,
                modifier = Modifier.testTag("ai_rule_toggle_${rule.id}"),
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    if (rule.policyAvailable && !unavailable) {
                        MaterialTheme.colorScheme.primaryContainer
                    } else {
                        MaterialTheme.colorScheme.errorContainer
                    },
                    RoundedCornerShape(12.dp),
                )
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                stringResource(R.string.rules_exit_direction),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                presentation.destinationLabel.resolve(),
                style = MaterialTheme.typography.titleMedium,
                color = if (rule.policyAvailable && !unavailable) {
                    MaterialTheme.colorScheme.onPrimaryContainer
                } else {
                    MaterialTheme.colorScheme.onErrorContainer
                },
                modifier = Modifier.testTag("ai_rule_exit_${rule.id}"),
            )
        }
        Text(
            stringResource(
                R.string.rules_profile_label,
                state.profileName ?: stringResource(R.string.rules_no_active_profile_name),
            ),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = onRebind, enabled = !busy) {
                Text(stringResource(R.string.rules_change_exit))
            }
            TextButton(onClick = onDelete, enabled = !busy) {
                Text(stringResource(R.string.common_delete))
            }
            if (busy) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .padding(10.dp)
                        .height(20.dp),
                    strokeWidth = 2.dp,
                )
            }
        }
    }
}

@Composable
private fun EmptyRules(message: String) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            message,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(28.dp),
        )
    }
}

@Composable
private fun PolicyPickerDialog(
    current: String,
    policies: List<String>,
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rules_select_exit)) },
        text = {
            LazyColumn(modifier = Modifier.heightIn(max = 420.dp)) {
                items(policies, key = { it }) { policy ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(policy) }
                            .padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(policy, modifier = Modifier.weight(1f))
                        if (policy == current) {
                            Text(
                                stringResource(R.string.rules_current),
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel)) }
        },
    )
}
