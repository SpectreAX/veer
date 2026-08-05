package com.yamax.veer.ui.rules

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.data.AiRuleHealth
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerDialog
import com.yamax.veer.ui.designsystem.components.VeerPrimaryButton
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerStateView
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.navigation.VeerBottomBar
import com.yamax.veer.ui.navigation.VeerTopLevelDestination
import com.yamax.veer.ui.navigation.navigateToTopLevel
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
                    onBack = { navigateToTopLevel(VeerTopLevelDestination.HOME) },
                    onRefresh = viewModel::refresh,
                    onReapply = viewModel::reapply,
                    onEnabledChange = viewModel::setEnabled,
                    onDelete = viewModel::delete,
                    onRebind = viewModel::rebind,
                    onDismissMessage = viewModel::clearMessage,
                    showBackNavigation = false,
                    bottomBar = {
                        VeerBottomBar(
                            selected = VeerTopLevelDestination.RULES,
                            onSelect = ::navigateToTopLevel,
                        )
                    },
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
    showBackNavigation: Boolean = true,
    bottomBar: @Composable () -> Unit = {},
) {
    var rebindRule by remember { mutableStateOf<ManagedAiRule?>(null) }
    var deleteRule by remember { mutableStateOf<ManagedAiRule?>(null) }

    deleteRule?.let { rule ->
        val presentation = aiRulePresentation(rule)
        VeerDialog(
            title = stringResource(R.string.rules_delete_title),
            body = stringResource(
                R.string.rules_delete_body,
                presentation.routeSummary.resolve(),
            ),
            confirmText = stringResource(R.string.common_delete),
            onConfirm = {
                deleteRule = null
                onDelete(rule.id)
            },
            dismissText = stringResource(R.string.common_cancel),
            onDismiss = { deleteRule = null },
        )
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

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("rules_screen"),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.rules_title),
                onBack = if (showBackNavigation) onBack else null,
                backContentDescription = stringResource(R.string.common_back),
            )
        },
        bottomBar = bottomBar,
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
                RulesSummary(state = state)

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                ) {
                    VeerSecondaryButton(
                        text = stringResource(R.string.common_refresh),
                        onClick = onRefresh,
                        enabled = !state.loading,
                        modifier = Modifier.weight(1f),
                    )
                    VeerPrimaryButton(
                        text = stringResource(R.string.rules_reapply),
                        onClick = onReapply,
                        enabled = state.profileId != null && !state.loading,
                        loading = state.loading && state.rules.isNotEmpty(),
                        modifier = Modifier.weight(1f),
                    )
                }

                state.message?.let { message ->
                    VeerCard(
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                            verticalAlignment = Alignment.CenterVertically,
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

                RulesContent(
                    state = state,
                    onEnabledChange = onEnabledChange,
                    onRebind = { rebindRule = it },
                    onDelete = { deleteRule = it },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun RulesSummary(state: RulesUiState) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = state.profileName ?: stringResource(R.string.rules_no_active_profile_name),
            style = MaterialTheme.typography.titleMedium,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerStatusBadge(
                status = when {
                    state.loading -> VeerStatus.Loading
                    state.engineRunning -> VeerStatus.Connected
                    else -> VeerStatus.Disconnected
                },
                label = stringResource(
                    when {
                        state.loading -> R.string.rules_status_refreshing
                        state.engineRunning -> R.string.rules_runtime_connected
                        else -> R.string.rules_runtime_disconnected
                    },
                ),
            )
            Text(
                text = stringResource(R.string.rules_count, state.rules.size),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun RulesContent(
    state: RulesUiState,
    onEnabledChange: (String, Boolean) -> Unit,
    onRebind: (ManagedAiRule) -> Unit,
    onDelete: (ManagedAiRule) -> Unit,
    modifier: Modifier = Modifier,
) {
    when {
        state.loading && state.rules.isEmpty() -> VeerStateView(
            title = stringResource(R.string.rules_loading),
            description = stringResource(R.string.rules_loading_description),
            loading = true,
            modifier = modifier.fillMaxWidth(),
        )

        state.profileId == null -> VeerStateView(
            icon = Icons.Default.Info,
            iconContentDescription = null,
            title = stringResource(R.string.rules_no_profile_title),
            description = stringResource(R.string.rules_activate_profile_first),
            modifier = modifier.fillMaxWidth(),
        )

        state.rules.isEmpty() -> VeerStateView(
            icon = Icons.Default.Info,
            iconContentDescription = null,
            title = stringResource(R.string.rules_empty_title),
            description = stringResource(R.string.rules_empty),
            modifier = modifier.fillMaxWidth(),
        )

        else -> LazyColumn(
            modifier = modifier
                .fillMaxWidth()
                .testTag("ai_rule_list"),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            items(state.rules, key = ManagedAiRule::id) { rule ->
                RuleCard(
                    rule = rule,
                    state = state,
                    onEnabledChange = { onEnabledChange(rule.id, it) },
                    onRebind = { onRebind(rule) },
                    onDelete = { onDelete(rule) },
                )
            }
        }
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
    val health = ruleHealthPresentation(rule, state, unavailable)
    val busy = state.busyRuleId == rule.id

    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("ai_rule_${rule.id}"),
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Text(
            text = presentation.routeSummary.resolve(),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.testTag("ai_rule_route_${rule.id}"),
        )
        Text(
            text = presentation.matchDescription.resolve(),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerStatusBadge(
                status = if (busy) VeerStatus.Loading else health.status,
                label = stringResource(
                    if (busy) R.string.rules_health_updating else health.labelResource,
                ),
                modifier = Modifier.weight(1f, fill = false),
            )
            Text(
                text = stringResource(
                    if (rule.enabled) R.string.rules_enabled_short
                    else R.string.rules_disabled_short,
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
            Switch(
                checked = rule.enabled,
                onCheckedChange = onEnabledChange,
                enabled = !busy,
                modifier = Modifier.testTag("ai_rule_toggle_${rule.id}"),
            )
        }

        VeerCard(
            modifier = Modifier.fillMaxWidth(),
            containerColor = when {
                !rule.enabled -> MaterialTheme.colorScheme.surfaceContainerHighest
                rule.policyAvailable && !unavailable -> MaterialTheme.colorScheme.secondaryContainer
                else -> MaterialTheme.colorScheme.errorContainer
            },
        ) {
            Text(
                text = stringResource(R.string.rules_exit_direction),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
            Text(
                text = presentation.destinationLabel.resolve(),
                color = when {
                    !rule.enabled -> MaterialTheme.colorScheme.onSurfaceVariant
                    rule.policyAvailable && !unavailable -> {
                        MaterialTheme.colorScheme.onSecondaryContainer
                    }
                    else -> MaterialTheme.colorScheme.onErrorContainer
                },
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.testTag("ai_rule_exit_${rule.id}"),
            )
        }

        Text(
            text = stringResource(
                R.string.rules_profile_label,
                state.profileName ?: stringResource(R.string.rules_no_active_profile_name),
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerSecondaryButton(
                text = stringResource(R.string.rules_change_exit),
                onClick = onRebind,
                enabled = !busy && state.availablePolicies.isNotEmpty(),
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = onDelete,
                enabled = !busy,
                modifier = Modifier.heightIn(min = VeerDimensions.touchTarget),
            ) {
                Text(stringResource(R.string.common_delete))
            }
        }
    }
}

private data class RuleHealthPresentation(
    val status: VeerStatus,
    val labelResource: Int,
)

private fun ruleHealthPresentation(
    rule: ManagedAiRule,
    state: RulesUiState,
    unavailable: Boolean,
): RuleHealthPresentation = when {
    !rule.enabled -> RuleHealthPresentation(
        VeerStatus.Unavailable,
        R.string.rules_health_disabled,
    )
    !rule.policyAvailable -> RuleHealthPresentation(
        VeerStatus.Warning,
        R.string.rules_health_policy_missing,
    )
    unavailable -> RuleHealthPresentation(
        VeerStatus.Warning,
        R.string.rules_health_node_unavailable,
    )
    !state.engineRunning || rule.health == AiRuleHealth.NOT_LOADED -> RuleHealthPresentation(
        VeerStatus.Unavailable,
        R.string.rules_health_not_loaded,
    )
    else -> RuleHealthPresentation(VeerStatus.Connected, R.string.rules_health_running)
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
            LazyColumn(modifier = Modifier.heightIn(max = VeerDimensions.dialogListMaxHeight)) {
                items(policies, key = { it }) { policy ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = VeerDimensions.touchTarget)
                            .clickable { onSelect(policy) }
                            .padding(vertical = VeerSpacing.sm),
                        horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(policy, modifier = Modifier.weight(1f))
                        if (policy == current) {
                            VeerStatusBadge(
                                status = VeerStatus.Connected,
                                label = stringResource(R.string.rules_current),
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            VeerSecondaryButton(
                text = stringResource(R.string.common_cancel),
                onClick = onDismiss,
            )
        },
        shape = VeerShapes.extraLarge,
    )
}

private val PreviewRules = listOf(
    ManagedAiRule(
        id = "preview-netflix",
        raw = "GEOSITE,netflix,Japan Tokyo premium streaming and AI route",
        matchType = "GEOSITE",
        target = "netflix",
        policy = "Japan Tokyo premium streaming and AI route",
        enabled = true,
        policyAvailable = true,
        loadedInMaterializedConfig = true,
    ),
    ManagedAiRule(
        id = "preview-chatgpt",
        raw = "DOMAIN-SUFFIX,openai.com,United States West 03",
        matchType = "DOMAIN-SUFFIX",
        target = "openai.com",
        policy = "United States West 03",
        enabled = false,
        policyAvailable = true,
        loadedInMaterializedConfig = false,
    ),
)

@VeerThemePreviews
@Composable
private fun RulesNormalPreview() {
    VeerPreview {
        RulesScreen(
            state = RulesUiState(
                profileName = "Work, streaming and AI subscription",
                profileId = "preview",
                rules = PreviewRules,
                availablePolicies = listOf(
                    "Japan Tokyo premium streaming and AI route",
                    "Hong Kong 02",
                    "United States West 03",
                ),
                engineRunning = true,
                loading = false,
            ),
            onBack = {}, onRefresh = {}, onReapply = {}, onEnabledChange = { _, _ -> },
            onDelete = {}, onRebind = { _, _ -> }, onDismissMessage = {},
        )
    }
}

@VeerResponsivePreviews
@Composable
private fun RulesResponsivePreview() {
    VeerPreview {
        RulesScreen(
            state = RulesUiState(
                profileName = "Work, streaming and AI subscription with a very long name",
                profileId = "preview",
                rules = PreviewRules,
                availablePolicies = listOf("Japan Tokyo premium streaming and AI route"),
                engineRunning = false,
                loading = false,
            ),
            onBack = {}, onRefresh = {}, onReapply = {}, onEnabledChange = { _, _ -> },
            onDelete = {}, onRebind = { _, _ -> }, onDismissMessage = {},
        )
    }
}

@VeerThemePreviews
@Composable
private fun RulesEmptyPreview() {
    VeerPreview {
        RulesScreen(
            state = RulesUiState(profileId = "preview", loading = false),
            onBack = {}, onRefresh = {}, onReapply = {}, onEnabledChange = { _, _ -> },
            onDelete = {}, onRebind = { _, _ -> }, onDismissMessage = {},
        )
    }
}
