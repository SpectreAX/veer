package com.yamax.veer.ui.dns

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.R
import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsSettingField
import com.yamax.veer.core_profile.DnsValidationIssue
import com.yamax.veer.core_profile.DnsValidationProblem
import com.yamax.veer.core_profile.ProfileId
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
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onBack) { Text(stringResource(R.string.common_back)) }
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.dns_title), style = MaterialTheme.typography.headlineSmall)
                    Text(
                        state.profileName.ifBlank {
                            stringResource(R.string.dns_no_profile_selected)
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (state.loading) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalArrangement = Arrangement.Center,
                ) {
                    CircularProgressIndicator()
                }
                return@Column
            }

            Text(
                stringResource(
                    when {
                        !state.isActiveProfile -> R.string.dns_context_inactive
                        state.reconnectRequired -> R.string.dns_context_running
                        else -> R.string.dns_context_stopped
                    },
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            DnsModeCard(
                selected = state.policy.mode,
                enabled = !state.saving,
                onModeChange = onModeChange,
            )

            if (state.policy.mode == DnsOverrideMode.CUSTOM) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    ),
                ) {
                    Column(
                        modifier = Modifier.padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            stringResource(R.string.dns_resolution_mode),
                            style = MaterialTheme.typography.titleSmall,
                        )
                        EnhancedModeRow(
                            title = "Fake IP",
                            description = stringResource(R.string.dns_fake_ip_description),
                            mode = DnsEnhancedMode.FAKE_IP,
                            selected = state.policy.enhancedMode,
                            enabled = !state.saving,
                            onChange = onEnhancedModeChange,
                        )
                        EnhancedModeRow(
                            title = "Redir Host",
                            description = stringResource(R.string.dns_redir_host_description),
                            mode = DnsEnhancedMode.REDIR_HOST,
                            selected = state.policy.enhancedMode,
                            enabled = !state.saving,
                            onChange = onEnhancedModeChange,
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(stringResource(R.string.dns_ipv6_response))
                                Text(
                                    stringResource(R.string.dns_ipv6_description),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(
                                checked = state.policy.ipv6,
                                onCheckedChange = onIpv6Change,
                                enabled = !state.saving,
                            )
                        }
                    }
                }

                DnsEndpointField(
                    label = stringResource(R.string.dns_bootstrap_label),
                    description = stringResource(R.string.dns_bootstrap_description),
                    value = state.policy.defaultNameservers.joinToString("\n"),
                    enabled = !state.saving,
                    testTag = "dns_bootstrap_input",
                    onValueChange = onDefaultNameserversChange,
                )
                DnsEndpointField(
                    label = stringResource(R.string.dns_primary_label),
                    description = stringResource(R.string.dns_primary_description),
                    value = state.policy.nameservers.joinToString("\n"),
                    enabled = !state.saving,
                    testTag = "dns_primary_input",
                    onValueChange = onNameserversChange,
                )
                DnsEndpointField(
                    label = stringResource(R.string.dns_fallback_label),
                    description = stringResource(R.string.dns_fallback_description),
                    value = state.policy.fallbackNameservers.joinToString("\n"),
                    enabled = !state.saving,
                    testTag = "dns_fallback_input",
                    onValueChange = onFallbackNameserversChange,
                )
            } else {
                Text(
                    stringResource(R.string.dns_inherit_notice),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (state.validationIssues.isNotEmpty()) {
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("dns_validation_errors"),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                    ),
                ) {
                    Column(
                        modifier = Modifier.padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(
                            stringResource(R.string.dns_validation_title),
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                        )
                        state.validationIssues.forEach { issue ->
                            val field = stringResource(
                                when (issue.field) {
                                    DnsSettingField.DEFAULT_NAMESERVERS ->
                                        R.string.dns_validation_field_bootstrap
                                    DnsSettingField.NAMESERVERS ->
                                        R.string.dns_validation_field_primary
                                    DnsSettingField.FALLBACK_NAMESERVERS ->
                                        R.string.dns_validation_field_fallback
                                },
                            )
                            val index = issue.index?.let {
                                stringResource(R.string.dns_validation_line, it + 1)
                            }.orEmpty()
                            Text(
                                stringResource(
                                    R.string.dns_validation_bullet,
                                    field,
                                    index,
                                    issue.localizedMessage(),
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onErrorContainer,
                            )
                        }
                    }
                }
            }

            state.message?.let { message ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        message.resolve(),
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (state.messageIsError) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.primary
                        },
                    )
                    TextButton(onClick = onDismissMessage) {
                        Text(stringResource(R.string.common_close))
                    }
                }
            }

            Button(
                onClick = onSave,
                enabled = state.canSave,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("save_dns_settings"),
            ) {
                Text(
                    when {
                        state.saving -> stringResource(R.string.dns_applying)
                        state.reconnectRequired -> stringResource(R.string.dns_save_reconnect)
                        else -> stringResource(R.string.common_save)
                    },
                )
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun DnsModeCard(
    selected: DnsOverrideMode,
    enabled: Boolean,
    onModeChange: (DnsOverrideMode) -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Column(modifier = Modifier.padding(vertical = 4.dp)) {
            DnsModeRow(
                title = stringResource(R.string.dns_mode_inherit),
                description = stringResource(R.string.dns_mode_inherit_description),
                mode = DnsOverrideMode.INHERIT,
                selected = selected,
                enabled = enabled,
                onChange = onModeChange,
            )
            DnsModeRow(
                title = stringResource(R.string.dns_mode_custom),
                description = stringResource(R.string.dns_mode_custom_description),
                mode = DnsOverrideMode.CUSTOM,
                selected = selected,
                enabled = enabled,
                onChange = onModeChange,
            )
        }
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
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == mode,
            onClick = { onChange(mode) },
            enabled = enabled,
            modifier = Modifier.testTag(
                if (mode == DnsOverrideMode.CUSTOM) "dns_custom_mode"
                else "dns_inherit_mode",
            ),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(title)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
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
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == mode,
            onClick = { onChange(mode) },
            enabled = enabled,
            modifier = Modifier.testTag(
                if (mode == DnsEnhancedMode.REDIR_HOST) "dns_redir_host_mode"
                else "dns_fake_ip_mode",
            ),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(title)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DnsEndpointField(
    label: String,
    description: String,
    value: String,
    enabled: Boolean,
    testTag: String,
    onValueChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(label) },
            minLines = 2,
            maxLines = 5,
            enabled = enabled,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(testTag),
        )
        Text(
            description,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun DnsValidationIssue.localizedMessage(): String = when (problem) {
    DnsValidationProblem.REQUIRED ->
        stringResource(R.string.dns_validation_required)
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
    DnsValidationProblem.MISSING_HOST ->
        stringResource(R.string.dns_validation_missing_host)
    DnsValidationProblem.INVALID_PORT ->
        stringResource(R.string.dns_validation_invalid_port)
    DnsValidationProblem.FRAGMENT_NOT_ALLOWED ->
        stringResource(R.string.dns_validation_fragment)
    DnsValidationProblem.DOH_PATH_REQUIRED ->
        stringResource(R.string.dns_validation_doh_path)
    DnsValidationProblem.PATH_NOT_ALLOWED ->
        stringResource(R.string.dns_validation_path_not_allowed, argument.orEmpty())
}
