package com.yamax.veer.ui.dns

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.core_profile.DnsOverrideValidator
import com.yamax.veer.core_profile.DnsSettingField
import com.yamax.veer.core_profile.DnsValidationIssue
import com.yamax.veer.core_profile.DnsValidationProblem
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.ui.UiText
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
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.theme.VeerTheme

class DnsSettingsActivity : ComponentActivity() {
    private val viewModel: DnsSettingsViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val profileId = intent.getStringExtra(EXTRA_PROFILE_ID)
            ?.takeIf(String::isNotBlank)
            ?.let(::ProfileId)
        setContent {
            VeerTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                LaunchedEffect(profileId) {
                    viewModel.load(profileId)
                }
                DnsSettingsScreen(
                    state = state,
                    onBack = ::finish,
                    onModeChange = viewModel::setMode,
                    onIpv6Change = viewModel::setIpv6,
                    onEnhancedModeChange = viewModel::setEnhancedMode,
                    onDefaultNameserversChange = viewModel::setDefaultNameservers,
                    onNameserversChange = viewModel::setNameservers,
                    onFallbackNameserversChange = viewModel::setFallbackNameservers,
                    onSave = viewModel::save,
                    onDismissMessage = viewModel::dismissMessage,
                )
            }
        }
    }

    companion object {
        private const val EXTRA_PROFILE_ID = "profile_id"

        internal fun intent(context: Context, profileId: ProfileId? = null): Intent =
            Intent(context, DnsSettingsActivity::class.java).apply {
                profileId?.let { putExtra(EXTRA_PROFILE_ID, it.value) }
            }
    }
}

@Composable
internal fun DnsSettingsScreen(
    state: DnsSettingsUiState,
    onBack: () -> Unit,
    onModeChange: (DnsOverrideMode) -> Unit,
    onIpv6Change: (Boolean) -> Unit,
    onEnhancedModeChange: (DnsEnhancedMode) -> Unit,
    onDefaultNameserversChange: (String) -> Unit,
    onNameserversChange: (String) -> Unit,
    onFallbackNameserversChange: (String) -> Unit,
    onSave: () -> Unit,
    onDismissMessage: () -> Unit,
) {
    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("dns_settings_screen"),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.dns_title),
                onBack = onBack,
                backContentDescription = stringResource(R.string.common_back),
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentAlignment = Alignment.TopCenter,
        ) {
            when {
                state.loading -> VeerStateView(
                    title = stringResource(R.string.dns_loading),
                    description = stringResource(R.string.dns_loading_description),
                    loading = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = VeerDimensions.formMaxWidth),
                )

                state.profileId == null -> VeerStateView(
                    icon = Icons.Default.Warning,
                    iconContentDescription = null,
                    title = stringResource(R.string.dns_no_profile_title),
                    description = state.message?.resolve()
                        ?: stringResource(R.string.dns_no_profile_error),
                    actionText = stringResource(R.string.common_back),
                    onAction = onBack,
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = VeerDimensions.formMaxWidth),
                )

                else -> DnsSettingsForm(
                    state = state,
                    onModeChange = onModeChange,
                    onIpv6Change = onIpv6Change,
                    onEnhancedModeChange = onEnhancedModeChange,
                    onDefaultNameserversChange = onDefaultNameserversChange,
                    onNameserversChange = onNameserversChange,
                    onFallbackNameserversChange = onFallbackNameserversChange,
                    onSave = onSave,
                    onDismissMessage = onDismissMessage,
                    modifier = Modifier
                        .fillMaxSize()
                        .widthIn(max = VeerDimensions.formMaxWidth),
                )
            }
        }
    }
}

@Composable
private fun DnsSettingsForm(
    state: DnsSettingsUiState,
    onModeChange: (DnsOverrideMode) -> Unit,
    onIpv6Change: (Boolean) -> Unit,
    onEnhancedModeChange: (DnsEnhancedMode) -> Unit,
    onDefaultNameserversChange: (String) -> Unit,
    onNameserversChange: (String) -> Unit,
    onFallbackNameserversChange: (String) -> Unit,
    onSave: () -> Unit,
    onDismissMessage: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = VeerSpacing.lg, vertical = VeerSpacing.md),
        verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
    ) {
        DnsContextCard(state = state)

        DnsSection(title = stringResource(R.string.dns_section_source)) {
            DnsModeRow(
                title = stringResource(R.string.dns_mode_inherit),
                description = stringResource(R.string.dns_mode_inherit_description),
                mode = DnsOverrideMode.INHERIT,
                selected = state.policy.mode,
                enabled = !state.saving,
                onChange = onModeChange,
            )
            DnsModeRow(
                title = stringResource(R.string.dns_mode_custom),
                description = stringResource(R.string.dns_mode_custom_description),
                mode = DnsOverrideMode.CUSTOM,
                selected = state.policy.mode,
                enabled = !state.saving,
                onChange = onModeChange,
            )
        }

        if (state.policy.mode == DnsOverrideMode.CUSTOM) {
            DnsSection(title = stringResource(R.string.dns_resolution_mode)) {
                EnhancedModeRow(
                    title = stringResource(R.string.dns_fake_ip_title),
                    description = stringResource(R.string.dns_fake_ip_description),
                    mode = DnsEnhancedMode.FAKE_IP,
                    selected = state.policy.enhancedMode,
                    enabled = !state.saving,
                    onChange = onEnhancedModeChange,
                )
                EnhancedModeRow(
                    title = stringResource(R.string.dns_redir_host_title),
                    description = stringResource(R.string.dns_redir_host_description),
                    mode = DnsEnhancedMode.REDIR_HOST,
                    selected = state.policy.enhancedMode,
                    enabled = !state.saving,
                    onChange = onEnhancedModeChange,
                )
                VeerSettingsRow(
                    title = stringResource(R.string.dns_ipv6_response),
                    description = stringResource(R.string.dns_ipv6_description),
                    enabled = !state.saving,
                    onClick = { onIpv6Change(!state.policy.ipv6) },
                    trailingContent = {
                        Switch(
                            checked = state.policy.ipv6,
                            onCheckedChange = onIpv6Change,
                            enabled = !state.saving,
                        )
                    },
                )
            }

            Text(
                text = stringResource(R.string.dns_section_servers),
                style = MaterialTheme.typography.titleMedium,
            )
            DnsEndpointField(
                label = stringResource(R.string.dns_bootstrap_label),
                description = stringResource(R.string.dns_bootstrap_description),
                value = state.policy.defaultNameservers.joinToString("\n"),
                enabled = !state.saving,
                testTag = "dns_bootstrap_input",
                issue = state.validationIssues.firstFor(DnsSettingField.DEFAULT_NAMESERVERS),
                onValueChange = onDefaultNameserversChange,
            )
            DnsEndpointField(
                label = stringResource(R.string.dns_primary_label),
                description = stringResource(R.string.dns_primary_description),
                value = state.policy.nameservers.joinToString("\n"),
                enabled = !state.saving,
                testTag = "dns_primary_input",
                issue = state.validationIssues.firstFor(DnsSettingField.NAMESERVERS),
                onValueChange = onNameserversChange,
            )
            DnsEndpointField(
                label = stringResource(R.string.dns_fallback_label),
                description = stringResource(R.string.dns_fallback_description),
                value = state.policy.fallbackNameservers.joinToString("\n"),
                enabled = !state.saving,
                testTag = "dns_fallback_input",
                issue = state.validationIssues.firstFor(DnsSettingField.FALLBACK_NAMESERVERS),
                onValueChange = onFallbackNameserversChange,
            )
        } else {
            VeerCard(
                modifier = Modifier.fillMaxWidth(),
                containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            ) {
                Text(
                    text = stringResource(R.string.dns_inherit_notice),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        if (state.validationIssues.isNotEmpty()) {
            DnsValidationSummary(issues = state.validationIssues)
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
                    VeerStatusBadge(
                        status = if (state.messageIsError) VeerStatus.Warning
                        else VeerStatus.Connected,
                        label = stringResource(
                            if (state.messageIsError) R.string.dns_message_attention
                            else R.string.dns_message_saved,
                        ),
                    )
                    Text(
                        text = message.resolve(),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f),
                    )
                    VeerSecondaryButton(
                        text = stringResource(R.string.common_close),
                        onClick = onDismissMessage,
                    )
                }
            }
        }

        VeerPrimaryButton(
            text = when {
                state.saving -> stringResource(R.string.dns_applying)
                state.reconnectRequired -> stringResource(R.string.dns_save_reconnect)
                else -> stringResource(R.string.common_save)
            },
            onClick = onSave,
            enabled = state.canSave,
            loading = state.saving,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("save_dns_settings"),
        )
    }
}

@Composable
private fun DnsContextCard(state: DnsSettingsUiState) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = state.profileName.ifBlank {
                stringResource(R.string.dns_no_profile_selected)
            },
            style = MaterialTheme.typography.titleMedium,
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeerStatusBadge(
                status = if (state.isActiveProfile) VeerStatus.Connected
                else VeerStatus.Unavailable,
                label = stringResource(
                    if (state.isActiveProfile) R.string.dns_profile_active
                    else R.string.dns_profile_inactive,
                ),
            )
            Text(
                text = stringResource(
                    when {
                        !state.isActiveProfile -> R.string.dns_context_inactive
                        state.reconnectRequired -> R.string.dns_context_running
                        else -> R.string.dns_context_stopped
                    },
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun DnsSection(
    title: String,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm)) {
        Text(text = title, style = MaterialTheme.typography.titleMedium)
        VeerCard(modifier = Modifier.fillMaxWidth(), content = content)
    }
}

@Composable
private fun DnsModeRow(
    title: String,
    description: String,
    mode: DnsOverrideMode,
    selected: DnsOverrideMode,
    enabled: Boolean,
    onChange: (DnsOverrideMode) -> Unit,
) {
    VeerSettingsRow(
        title = title,
        description = description,
        enabled = enabled,
        onClick = { onChange(mode) },
        trailingContent = {
            RadioButton(
                selected = selected == mode,
                onClick = { onChange(mode) },
                enabled = enabled,
                modifier = Modifier.testTag(
                    if (mode == DnsOverrideMode.CUSTOM) "dns_custom_mode"
                    else "dns_inherit_mode",
                ),
            )
        },
    )
}

@Composable
private fun EnhancedModeRow(
    title: String,
    description: String,
    mode: DnsEnhancedMode,
    selected: DnsEnhancedMode,
    enabled: Boolean,
    onChange: (DnsEnhancedMode) -> Unit,
) {
    VeerSettingsRow(
        title = title,
        description = description,
        enabled = enabled,
        onClick = { onChange(mode) },
        trailingContent = {
            RadioButton(
                selected = selected == mode,
                onClick = { onChange(mode) },
                enabled = enabled,
                modifier = Modifier.testTag(
                    if (mode == DnsEnhancedMode.REDIR_HOST) "dns_redir_host_mode"
                    else "dns_fake_ip_mode",
                ),
            )
        },
    )
}

@Composable
private fun DnsEndpointField(
    label: String,
    description: String,
    value: String,
    enabled: Boolean,
    testTag: String,
    issue: DnsValidationIssue?,
    onValueChange: (String) -> Unit,
) {
    VeerTextField(
        value = value,
        onValueChange = onValueChange,
        label = label,
        supportingText = description,
        errorText = issue?.displayMessage(),
        enabled = enabled,
        minLines = 2,
        maxLines = 5,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(testTag),
    )
}

@Composable
private fun DnsValidationSummary(issues: List<DnsValidationIssue>) {
    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("dns_validation_errors"),
        containerColor = MaterialTheme.colorScheme.errorContainer,
    ) {
        Text(
            text = stringResource(R.string.dns_validation_title),
            color = MaterialTheme.colorScheme.onErrorContainer,
            style = MaterialTheme.typography.titleSmall,
        )
        issues.forEach { issue ->
            Text(
                text = issue.summaryLine(),
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

private fun List<DnsValidationIssue>.firstFor(field: DnsSettingField): DnsValidationIssue? =
    firstOrNull { it.field == field }

@Composable
private fun DnsValidationIssue.displayMessage(): String {
    val line = index?.let { stringResource(R.string.dns_validation_line, it + 1) }.orEmpty()
    return "$line${if (line.isEmpty()) "" else " "}${localizedMessage()}".trim()
}

@Composable
private fun DnsValidationIssue.summaryLine(): String {
    val fieldName = stringResource(
        when (field) {
            DnsSettingField.DEFAULT_NAMESERVERS -> R.string.dns_validation_field_bootstrap
            DnsSettingField.NAMESERVERS -> R.string.dns_validation_field_primary
            DnsSettingField.FALLBACK_NAMESERVERS -> R.string.dns_validation_field_fallback
        },
    )
    val line = index?.let { stringResource(R.string.dns_validation_line, it + 1) }.orEmpty()
    return stringResource(
        R.string.dns_validation_bullet,
        fieldName,
        line,
        localizedMessage(),
    )
}

@Composable
private fun DnsValidationIssue.localizedMessage(): String = when (problem) {
    DnsValidationProblem.REQUIRED -> stringResource(R.string.dns_validation_required)
    DnsValidationProblem.TOO_MANY ->
        stringResource(R.string.dns_validation_too_many, argument.orEmpty())
    DnsValidationProblem.TOO_LONG ->
        stringResource(R.string.dns_validation_too_long, argument.orEmpty())
    DnsValidationProblem.BOOTSTRAP_IP_ONLY ->
        stringResource(R.string.dns_validation_bootstrap_ip_only)
    DnsValidationProblem.INVALID_ADDRESS ->
        stringResource(R.string.dns_validation_invalid_address)
    DnsValidationProblem.BARE_DOMAIN_REQUIRES_PROTOCOL ->
        stringResource(R.string.dns_validation_bare_domain)
    DnsValidationProblem.UNSUPPORTED_SCHEME ->
        stringResource(R.string.dns_validation_unsupported_scheme, argument.orEmpty())
    DnsValidationProblem.CREDENTIALS_NOT_ALLOWED ->
        stringResource(R.string.dns_validation_credentials)
    DnsValidationProblem.MISSING_HOST -> stringResource(R.string.dns_validation_missing_host)
    DnsValidationProblem.INVALID_PORT -> stringResource(R.string.dns_validation_invalid_port)
    DnsValidationProblem.FRAGMENT_NOT_ALLOWED ->
        stringResource(R.string.dns_validation_fragment)
    DnsValidationProblem.DOH_PATH_REQUIRED -> stringResource(R.string.dns_validation_doh_path)
    DnsValidationProblem.PATH_NOT_ALLOWED ->
        stringResource(R.string.dns_validation_path_not_allowed, argument.orEmpty())
}

private val PreviewDnsPolicy = DnsOverridePolicy(
    mode = DnsOverrideMode.CUSTOM,
    ipv6 = true,
    enhancedMode = DnsEnhancedMode.FAKE_IP,
    defaultNameservers = listOf("223.5.5.5", "1.1.1.1"),
    nameservers = listOf(
        "https://1.1.1.1/dns-query",
        "https://cloudflare-dns.com/dns-query",
    ),
    fallbackNameservers = listOf("tls://dns.google"),
)

@VeerThemePreviews
@Composable
private fun DnsSettingsNormalPreview() {
    VeerPreview {
        DnsSettingsScreen(
            state = DnsSettingsUiState(
                loading = false,
                profileId = ProfileId("preview"),
                profileName = "Work, streaming and AI subscription",
                isActiveProfile = true,
                runtimeState = EngineState.Running,
                policy = PreviewDnsPolicy,
            ),
            onBack = {}, onModeChange = {}, onIpv6Change = {},
            onEnhancedModeChange = {}, onDefaultNameserversChange = {},
            onNameserversChange = {}, onFallbackNameserversChange = {},
            onSave = {}, onDismissMessage = {},
        )
    }
}

@VeerResponsivePreviews
@Composable
private fun DnsSettingsResponsivePreview() {
    VeerPreview {
        DnsSettingsScreen(
            state = DnsSettingsUiState(
                loading = false,
                profileId = ProfileId("preview"),
                profileName = "Work, streaming and AI subscription with a long name",
                isActiveProfile = true,
                runtimeState = EngineState.Running,
                policy = PreviewDnsPolicy,
            ),
            onBack = {}, onModeChange = {}, onIpv6Change = {},
            onEnhancedModeChange = {}, onDefaultNameserversChange = {},
            onNameserversChange = {}, onFallbackNameserversChange = {},
            onSave = {}, onDismissMessage = {},
        )
    }
}

@VeerThemePreviews
@Composable
private fun DnsSettingsValidationPreview() {
    val invalid = DnsOverridePolicy(mode = DnsOverrideMode.CUSTOM)
    VeerPreview {
        DnsSettingsScreen(
            state = DnsSettingsUiState(
                loading = false,
                profileId = ProfileId("preview"),
                profileName = "Validation preview",
                policy = invalid,
                validationIssues = DnsOverrideValidator.validate(invalid),
                message = UiText.Verbatim("DNS settings need attention."),
                messageIsError = true,
            ),
            onBack = {}, onModeChange = {}, onIpv6Change = {},
            onEnhancedModeChange = {}, onDefaultNameserversChange = {},
            onNameserversChange = {}, onFallbackNameserversChange = {},
            onSave = {}, onDismissMessage = {},
        )
    }
}
