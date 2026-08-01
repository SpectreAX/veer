package com.yamax.veer.ui.settings

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import androidx.annotation.StringRes
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.BuildConfig
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_compatibility.BackgroundRestrictionMonitor
import com.yamax.veer.core_compatibility.BackgroundRestrictionStatus
import com.yamax.veer.core_compatibility.BackgroundSettingsNavigator
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.data.PerAppProxyPolicyStore
import com.yamax.veer.ui.BackgroundProtectionCard
import com.yamax.veer.ui.dns.DnsSettingsActivity
import com.yamax.veer.ui.perapp.PerAppProxyActivity
import com.yamax.veer.ui.theme.ThemeMode
import com.yamax.veer.ui.theme.ThemePreference
import com.yamax.veer.ui.theme.VeerTheme

class SettingsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val themeMode by ThemePreference.mode.collectAsStateWithLifecycle()
            VeerTheme(themeMode = themeMode) {
                val appState by AppStateRepository.appState.collectAsStateWithLifecycle()
                val activeProfileId = appState.profile.activeProfileId
                val activeProfileName = appState.profile.activeMetadata?.displayName
                    ?: activeProfileId?.value
                SettingsRoute(
                    activeProfileId = activeProfileId,
                    activeProfileName = activeProfileName,
                    themeMode = themeMode,
                    onBack = ::finish,
                    onThemeModeChange = { ThemePreference.set(this, it) },
                )
            }
        }
    }
}

@Composable
private fun SettingsRoute(
    activeProfileId: ProfileId?,
    activeProfileName: String?,
    themeMode: ThemeMode,
    onBack: () -> Unit,
    onThemeModeChange: (ThemeMode) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasApiKey by remember { mutableStateOf(ApiKeyStore.hasUserKey(context)) }
    var perAppPolicy by remember { mutableStateOf(PerAppProxyPolicyStore.read(context)) }
    var backgroundStatus by remember {
        mutableStateOf(BackgroundRestrictionMonitor.snapshot(context))
    }

    DisposableEffect(context, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasApiKey = ApiKeyStore.hasUserKey(context)
                perAppPolicy = PerAppProxyPolicyStore.read(context)
                backgroundStatus = BackgroundRestrictionMonitor.snapshot(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    SettingsScreen(
        activeProfileName = activeProfileName,
        hasApiKey = hasApiKey,
        perAppPolicy = perAppPolicy,
        backgroundStatus = backgroundStatus,
        themeMode = themeMode,
        onBack = onBack,
        onSaveApiKey = { key ->
            ApiKeyStore.setDeepseekKey(context, key)
            hasApiKey = true
        },
        onClearApiKey = {
            ApiKeyStore.clearDeepseekKey(context)
            hasApiKey = false
        },
        onOpenDns = {
            context.startActivity(DnsSettingsActivity.intent(context, activeProfileId))
        },
        onOpenPerApp = {
            context.startActivity(Intent(context, PerAppProxyActivity::class.java))
        },
        onThemeModeChange = onThemeModeChange,
        onOpenBatterySettings = {
            BackgroundSettingsNavigator.openBatteryAndBackground(context)
        },
        onOpenAutoStartSettings = {
            BackgroundSettingsNavigator.openAutoStart(context)
        },
        onOpenApplicationDetails = {
            BackgroundSettingsNavigator.openApplicationDetails(context)
        },
    )
}

@Composable
internal fun SettingsScreen(
    activeProfileName: String?,
    hasApiKey: Boolean,
    perAppPolicy: PerAppProxyPolicy,
    backgroundStatus: BackgroundRestrictionStatus,
    themeMode: ThemeMode,
    onBack: () -> Unit,
    onSaveApiKey: (String) -> Unit,
    onClearApiKey: () -> Unit,
    onOpenDns: () -> Unit,
    onOpenPerApp: () -> Unit,
    onThemeModeChange: (ThemeMode) -> Unit,
    onOpenBatterySettings: () -> Unit,
    onOpenAutoStartSettings: () -> Unit,
    onOpenApplicationDetails: () -> Unit,
) {
    var apiKeyInput by remember { mutableStateOf("") }
    var apiMessage by remember { mutableStateOf<Int?>(null) }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("settings_screen"),
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onBack) { Text(stringResource(R.string.common_back)) }
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.settings_title), style = MaterialTheme.typography.headlineSmall)
                    Text(
                        stringResource(R.string.settings_subtitle),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            SettingsSection(title = stringResource(R.string.settings_section_ai)) {
                Text(
                    stringResource(
                        if (hasApiKey) R.string.settings_api_key_saved
                        else R.string.settings_api_key_missing,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (hasApiKey) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = apiKeyInput,
                    onValueChange = {
                        apiKeyInput = it
                        apiMessage = null
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("settings_api_key"),
                    label = {
                        Text(
                            stringResource(
                                if (hasApiKey) R.string.settings_api_key_replace_label
                                else R.string.settings_api_key_label,
                            ),
                        )
                    },
                    placeholder = { Text("sk-…") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = {
                            onSaveApiKey(apiKeyInput)
                            apiKeyInput = ""
                            apiMessage = R.string.settings_api_key_saved_message
                        },
                        enabled = apiKeyInput.isNotBlank(),
                    ) {
                        Text(
                            stringResource(
                                if (hasApiKey) R.string.common_replace else R.string.common_save,
                            ),
                        )
                    }
                    TextButton(
                        onClick = {
                            onClearApiKey()
                            apiKeyInput = ""
                            apiMessage = R.string.settings_api_key_cleared_message
                        },
                        enabled = hasApiKey,
                    ) { Text(stringResource(R.string.common_clear)) }
                }
                apiMessage?.let { messageRes ->
                    Text(stringResource(messageRes), style = MaterialTheme.typography.bodySmall)
                }
            }

            SettingsSection(title = stringResource(R.string.settings_section_network)) {
                SettingsNavigationRow(
                    title = stringResource(R.string.settings_dns),
                    summary = activeProfileName?.let {
                        stringResource(R.string.settings_active_profile, it)
                    } ?: stringResource(R.string.settings_activate_profile_first),
                    enabled = activeProfileName != null,
                    onClick = onOpenDns,
                )
                SettingsNavigationRow(
                    title = stringResource(R.string.settings_per_app),
                    summary = perAppPolicy.settingsSummaryText().resolve(),
                    onClick = onOpenPerApp,
                )
            }

            SettingsSection(title = stringResource(R.string.settings_section_appearance)) {
                ThemeMode.entries.forEach { mode ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onThemeModeChange(mode) }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = themeMode == mode,
                            onClick = { onThemeModeChange(mode) },
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(stringResource(mode.displayNameRes()))
                            Text(
                                stringResource(mode.descriptionRes()),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }

            BackgroundProtectionCard(
                status = backgroundStatus,
                onOpenBatterySettings = onOpenBatterySettings,
                onOpenAutoStartSettings = onOpenAutoStartSettings,
                onOpenApplicationDetails = onOpenApplicationDetails,
                alwaysShow = true,
            )

            SettingsSection(title = stringResource(R.string.settings_section_about)) {
                Text(stringResource(R.string.settings_version, BuildConfig.VERSION_NAME))
                Text(
                    stringResource(
                        R.string.settings_build_info,
                        BuildConfig.APPLICATION_ID,
                        BuildConfig.VERSION_CODE,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    stringResource(R.string.settings_description),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun SettingsSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
private fun SettingsNavigationRow(
    title: String,
    summary: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                color = if (enabled) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
            )
            Text(
                summary,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            stringResource(if (enabled) R.string.common_enter else R.string.common_unavailable),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

internal data class SettingsText(
    @param:StringRes val resourceId: Int,
    val count: Int? = null,
)

internal fun PerAppProxyPolicy.settingsSummaryText(): SettingsText = when (mode) {
    PerAppProxyMode.ALL_APPS -> SettingsText(R.string.settings_per_app_all)
    PerAppProxyMode.ONLY_SELECTED ->
        SettingsText(R.string.settings_per_app_only, packageNames.size)
    PerAppProxyMode.BYPASS_SELECTED ->
        SettingsText(R.string.settings_per_app_bypass, packageNames.size)
}

@Composable
private fun SettingsText.resolve(): String = count?.let {
    stringResource(resourceId, it)
} ?: stringResource(resourceId)

@StringRes
internal fun ThemeMode.displayNameRes(): Int = when (this) {
    ThemeMode.SYSTEM -> R.string.theme_system
    ThemeMode.LIGHT -> R.string.theme_light
    ThemeMode.DARK -> R.string.theme_dark
}

@StringRes
private fun ThemeMode.descriptionRes(): Int = when (this) {
    ThemeMode.SYSTEM -> R.string.theme_system_description
    ThemeMode.LIGHT -> R.string.theme_light_description
    ThemeMode.DARK -> R.string.theme_dark_description
}
