package com.yamax.veer.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.ui.AiExecutionReadiness
import com.yamax.veer.ui.canExecute
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerPrimaryButton
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTextField
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.guidanceRes

internal data class HomeScreenState(
    val engineState: EngineState,
    val activeProfileName: String?,
    val activeProfileHash: String?,
    val prompt: TextFieldValue,
    val aiBusy: Boolean,
    val aiReadiness: AiExecutionReadiness,
    val aiFeedback: String?,
    val aiFeedbackIsError: Boolean,
)

@Composable
internal fun HomeScreen(
    state: HomeScreenState,
    primaryActionLabel: String,
    primaryActionEnabled: Boolean,
    onPrimaryAction: () -> Unit,
    onQuickReconnect: () -> Unit,
    onConnections: () -> Unit,
    onLogs: () -> Unit,
    onPromptChange: (TextFieldValue) -> Unit,
    onSubmitPrompt: () -> Unit,
    onDismissFeedback: () -> Unit,
    modifier: Modifier = Modifier,
    startupContent: @Composable () -> Unit = {},
    connectionContent: @Composable () -> Unit,
    quickTemplatesContent: @Composable () -> Unit = {},
    historyContent: @Composable () -> Unit = {},
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = VeerSpacing.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = VeerDimensions.contentMaxWidth)
                .padding(vertical = VeerSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.xl),
        ) {
            Text(
                text = stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineSmall,
            )

            RuntimeSection(
                state = state,
                primaryActionLabel = primaryActionLabel,
                primaryActionEnabled = primaryActionEnabled,
                onPrimaryAction = onPrimaryAction,
                onQuickReconnect = onQuickReconnect,
                startupContent = startupContent,
                connectionContent = connectionContent,
            )

            QuickActionsSection(
                runtimeConnected = state.engineState is EngineState.Running,
                onConnections = onConnections,
                onLogs = onLogs,
            )

            AiCommandSection(
                state = state,
                onPromptChange = onPromptChange,
                onSubmitPrompt = onSubmitPrompt,
                onDismissFeedback = onDismissFeedback,
                quickTemplatesContent = quickTemplatesContent,
            )

            historyContent()

        }
    }
}

@Composable
private fun RuntimeSection(
    state: HomeScreenState,
    primaryActionLabel: String,
    primaryActionEnabled: Boolean,
    onPrimaryAction: () -> Unit,
    onQuickReconnect: () -> Unit,
    startupContent: @Composable () -> Unit,
    connectionContent: @Composable () -> Unit,
) {
    VeerCard(modifier = Modifier.testTag("home_runtime_card")) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.connection_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            VeerStatusBadge(
                status = state.engineState.toVeerStatus(),
                label = state.engineState.localizedLabel(),
            )
        }

        val profileName = state.activeProfileName
        if (profileName == null) {
            Text(
                text = stringResource(R.string.home_no_profile),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            Text(
                text = stringResource(
                    R.string.home_active_profile,
                    profileName,
                    state.activeProfileHash.orEmpty().take(8),
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }

        startupContent()

        VeerPrimaryButton(
            text = primaryActionLabel,
            onClick = onPrimaryAction,
            enabled = primaryActionEnabled,
            loading = state.engineState is EngineState.Starting ||
                state.engineState is EngineState.Stopping,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("primary_vpn_action"),
        )
        if (state.engineState is EngineState.Running) {
            VeerSecondaryButton(
                text = stringResource(R.string.home_quick_reconnect),
                onClick = onQuickReconnect,
                modifier = Modifier
                    .fillMaxWidth()
                .testTag("quick_reconnect_action"),
            )
        }

        connectionContent()
    }
}

@Composable
private fun QuickActionsSection(
    runtimeConnected: Boolean,
    onConnections: () -> Unit,
    onLogs: () -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
    ) {
        Text(
            text = stringResource(R.string.home_diagnostics),
            style = MaterialTheme.typography.titleMedium,
        )
        QuickActionRow(
            firstText = stringResource(R.string.home_connections),
            onFirst = onConnections,
            firstEnabled = runtimeConnected,
            secondText = stringResource(R.string.home_live_logs),
            onSecond = onLogs,
        )
    }
}

@Composable
private fun QuickActionRow(
    firstText: String,
    onFirst: () -> Unit,
    secondText: String,
    onSecond: () -> Unit,
    firstEnabled: Boolean = true,
    secondEnabled: Boolean = true,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
    ) {
        VeerSecondaryButton(
            text = firstText,
            onClick = onFirst,
            enabled = firstEnabled,
            modifier = Modifier.weight(1f),
        )
        VeerSecondaryButton(
            text = secondText,
            onClick = onSecond,
            enabled = secondEnabled,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun AiCommandSection(
    state: HomeScreenState,
    onPromptChange: (TextFieldValue) -> Unit,
    onSubmitPrompt: () -> Unit,
    onDismissFeedback: () -> Unit,
    quickTemplatesContent: @Composable () -> Unit,
) {
    VeerCard {
        Text(
            text = stringResource(R.string.home_ai_command),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            text = stringResource(R.string.home_ai_command_description),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
        VeerTextField(
            value = state.prompt,
            onValueChange = onPromptChange,
            label = stringResource(R.string.home_ai_prompt_label),
            placeholder = stringResource(R.string.home_ai_prompt_placeholder),
            modifier = Modifier
                .fillMaxWidth()
                .testTag("ai_prompt"),
            enabled = !state.aiBusy,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Text,
                imeAction = ImeAction.Send,
            ),
            keyboardActions = KeyboardActions(onSend = { onSubmitPrompt() }),
        )

        if (state.prompt.text.isBlank()) quickTemplatesContent()

        Text(
            text = stringResource(state.aiReadiness.guidanceRes()),
            color = if (state.aiReadiness.canExecute) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.error
            },
            style = MaterialTheme.typography.bodySmall,
        )
        VeerSecondaryButton(
            text = aiActionLabel(state.aiBusy, state.aiReadiness),
            onClick = onSubmitPrompt,
            enabled = !state.aiBusy && state.prompt.text.isNotBlank() && state.aiReadiness.canExecute,
            loading = state.aiBusy,
            modifier = Modifier.fillMaxWidth(),
        )

        state.aiFeedback?.let { feedback ->
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = if (state.aiFeedbackIsError) {
                    MaterialTheme.colorScheme.errorContainer
                } else {
                    MaterialTheme.colorScheme.primaryContainer
                },
                shape = VeerShapes.medium,
            ) {
                Column(
                    modifier = Modifier.padding(VeerSpacing.md),
                    verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs),
                ) {
                    Text(
                        text = stringResource(
                            if (state.aiFeedbackIsError) R.string.home_ai_failed
                            else R.string.home_ai_complete,
                        ),
                        style = MaterialTheme.typography.titleSmall,
                    )
                    Text(text = feedback, style = MaterialTheme.typography.bodyMedium)
                    TextButton(onClick = onDismissFeedback) {
                        Text(stringResource(R.string.common_close))
                    }
                }
            }
        }
    }
}

@Composable
private fun aiActionLabel(busy: Boolean, readiness: AiExecutionReadiness): String = when {
    busy -> stringResource(R.string.home_ai_executing)
    readiness == AiExecutionReadiness.VPN_NOT_RUNNING ->
        stringResource(R.string.home_ai_connect_first)
    readiness == AiExecutionReadiness.LOCAL_ONLY ->
        stringResource(R.string.home_ai_execute_local)
    readiness == AiExecutionReadiness.NO_PROFILE ->
        stringResource(R.string.home_ai_import_first)
    else -> stringResource(R.string.home_ai_execute)
}

private fun EngineState.toVeerStatus(): VeerStatus = when (this) {
    EngineState.Stopped -> VeerStatus.Disconnected
    EngineState.Starting, EngineState.Stopping -> VeerStatus.Connecting
    EngineState.Running -> VeerStatus.Connected
    is EngineState.Error -> VeerStatus.Warning
}

@Composable
private fun EngineState.localizedLabel(): String = when (this) {
    EngineState.Stopped -> stringResource(R.string.engine_stopped)
    EngineState.Starting -> stringResource(R.string.engine_starting)
    EngineState.Running -> stringResource(R.string.engine_running)
    EngineState.Stopping -> stringResource(R.string.engine_stopping)
    is EngineState.Error -> stringResource(R.string.engine_error, message)
}

@VeerThemePreviews
@Composable
private fun HomeScreenPreview() {
    HomePreviewSample()
}

@VeerResponsivePreviews
@Composable
private fun HomeScreenResponsivePreview() {
    HomePreviewSample(
        profileName = "Work and entertainment subscription with a very long profile name",
        prompt = "Route Netflix through the fastest available Japanese node and keep ChatGPT on the United States policy group",
    )
}

@Composable
private fun HomePreviewSample(
    profileName: String = "Daily profile",
    prompt: String = "",
) {
    VeerPreview {
        HomeScreen(
            state = HomeScreenState(
                engineState = EngineState.Running,
                activeProfileName = profileName,
                activeProfileHash = "a11ce55f",
                prompt = TextFieldValue(prompt),
                aiBusy = false,
                aiReadiness = AiExecutionReadiness.READY,
                aiFeedback = null,
                aiFeedbackIsError = false,
            ),
            primaryActionLabel = "Disconnect VPN",
            primaryActionEnabled = true,
            onPrimaryAction = {},
            onQuickReconnect = {},
            onConnections = {},
            onLogs = {},
            onPromptChange = {},
            onSubmitPrompt = {},
            onDismissFeedback = {},
            connectionContent = {
                VeerCard {
                    Text("Tokyo 01 · 42 ms", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "Exit: Japan · 203.0.113.8",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            },
            quickTemplatesContent = {
                Text(
                    "Netflix Japan · ChatGPT US · Low latency",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelMedium,
                )
            },
            historyContent = {
                VeerCard {
                    Text("AI operation history", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "No operations yet",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
        )
    }
}
