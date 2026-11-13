package com.yamax.veer.ui.settings

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.BuildConfig
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_compatibility.AppStandbyBucket
import com.yamax.veer.core_compatibility.BackgroundRestrictionMonitor
import com.yamax.veer.core_compatibility.BackgroundRestrictionPolicy
import com.yamax.veer.core_compatibility.BackgroundRestrictionSignals
import com.yamax.veer.core_compatibility.BackgroundRestrictionStatus
import com.yamax.veer.core_compatibility.BackgroundSettingsNavigator
import com.yamax.veer.core_compatibility.OemFamily
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.data.PerAppProxyPolicyStore
import com.yamax.veer.ui.BackgroundProtectionCard
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerPrimaryButton
import com.yamax.veer.ui.designsystem.components.VeerSecondaryButton
import com.yamax.veer.ui.designsystem.components.VeerSettingsRow
import com.yamax.veer.ui.designsystem.components.VeerStatus
import com.yamax.veer.ui.designsystem.components.VeerStatusBadge
import com.yamax.veer.ui.designsystem.components.VeerTextField
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.dns.DnsSettingsActivity
import com.yamax.veer.ui.perapp.PerAppProxyActivity
import com.yamax.veer.ui.theme.ThemeMode
import com.yamax.veer.ui.theme.ThemePreference
import com.yamax.veer.ui.theme.VeerTheme
import com.yamax.veer.ui.navigation.VeerBottomBar
import com.yamax.veer.ui.navigation.VeerTopLevelBackHandler
import com.yamax.veer.ui.navigation.VeerTopLevelDestination
import com.yamax.veer.ui.navigation.navigateToTopLevel

class SettingsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val themeMode by ThemePreference.mode.collectAsStateWithLifecycle()
            VeerTheme(themeMode = themeMode) {
                VeerTopLevelBackHandler()
                val appState by AppStateRepository.appState.collectAsStateWithLifecycle()
                val activeProfileId = appState.profile.activeProfileId
                val activeProfileName = appState.profile.activeMetadata?.displayName
                    ?: activeProfileId?.value
                SettingsRoute(
                    activeProfileId = activeProfileId,
                    activeProfileName = activeProfileName,
                    themeMode = themeMode,
                    onBack = { navigateToTopLevel(VeerTopLevelDestination.HOME) },
                    onThemeModeChange = { ThemePreference.set(this, it) },
                    showBackNavigation = false,
                    bottomBar = {
                        VeerBottomBar(
                            selected = VeerTopLevelDestination.SETTINGS,
                            onSelect = ::navigateToTopLevel,
                        )
                    },
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
    showBackNavigation: Boolean,
    bottomBar: @Composable () -> Unit,
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
        showBackNavigation = showBackNavigation,
        bottomBar = bottomBar,
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
    showBackNavigation: Boolean = true,
    bottomBar: @Composable () -> Unit = {},
) {
    var apiKeyInput by remember { mutableStateOf("") }
    var apiMessage by remember { mutableStateOf<Int?>(null) }
    var apiKeyVisible by remember { mutableStateOf(false) }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("settings_screen"),
        topBar = {
            VeerTopAppBar(
                title = stringResource(R.string.settings_title),
                onBack = if (showBackNavigation) onBack else null,
                backContentDescription = stringResource(R.string.common_back),
            )
        },
        bottomBar = bottomBar,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VeerSpacing.lg, vertical = VeerSpacing.md),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = VeerDimensions.contentMaxWidth),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            ) {
                Text(
                    text = stringResource(R.string.settings_subtitle),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )

                SettingsSection(title = stringResource(R.string.settings_section_connection)) {
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

                SettingsSection(title = stringResource(R.string.settings_section_ai)) {
                    VeerStatusBadge(
                        status = if (hasApiKey) VeerStatus.Connected else VeerStatus.Unavailable,
                        label = stringResource(
                            if (hasApiKey) R.string.settings_api_key_saved
                            else R.string.settings_api_key_missing,
                        ),
                    )
                    VeerTextField(
                        value = apiKeyInput,
                        onValueChange = {
                            apiKeyInput = it
                            apiMessage = null
                        },
                        label = stringResource(
                            if (hasApiKey) R.string.settings_api_key_replace_label
                            else R.string.settings_api_key_label,
                        ),
                        placeholder = "sk-…",
                        singleLine = true,
                        visualTransformation = if (apiKeyVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        trailingIcon = {
                            TextButton(onClick = { apiKeyVisible = !apiKeyVisible }) {
                                Text(
                                    stringResource(
                                        if (apiKeyVisible) R.string.common_hide else R.string.common_show,
                                    ),
                                )
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("settings_api_key"),
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
                    ) {
                        VeerPrimaryButton(
                            text = stringResource(
                                if (hasApiKey) R.string.common_replace else R.string.common_save,
                            ),
                            onClick = {
                                onSaveApiKey(apiKeyInput)
                                apiKeyInput = ""
                                apiMessage = R.string.settings_api_key_saved_message
                            },
                            enabled = apiKeyInput.isNotBlank(),
                            modifier = Modifier.weight(1f),
                        )
                        VeerSecondaryButton(
                            text = stringResource(R.string.common_clear),
                            onClick = {
                                onClearApiKey()
                                apiKeyInput = ""
                                apiMessage = R.string.settings_api_key_cleared_message
                            },
                            enabled = hasApiKey,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    apiMessage?.let { messageRes ->
                        VeerStatusBadge(
                            status = VeerStatus.Connected,
                            label = stringResource(messageRes),
                        )
                    }
                }

                SettingsSection(title = stringResource(R.string.settings_section_appearance)) {
                    ThemeMode.entries.forEach { mode ->
                        VeerSettingsRow(
                            title = stringResource(mode.displayNameRes()),
                            description = stringResource(mode.descriptionRes()),
                            trailingContent = {
                                RadioButton(
                                    selected = themeMode == mode,
                                    onClick = null,
                                )
                            },
                            onClick = { onThemeModeChange(mode) },
                        )
                    }
                }

                Text(
                    text = stringResource(R.string.settings_section_system),
                    style = MaterialTheme.typography.titleMedium,
                )
                BackgroundProtectionCard(
                    status = backgroundStatus,
                    onOpenBatterySettings = onOpenBatterySettings,
                    onOpenAutoStartSettings = onOpenAutoStartSettings,
                    onOpenApplicationDetails = onOpenApplicationDetails,
                    alwaysShow = true,
                )

                SettingsSection(title = stringResource(R.string.settings_section_about)) {
                    VeerSettingsRow(
                        title = stringResource(R.string.settings_version, BuildConfig.VERSION_NAME),
                        description = stringResource(
                            R.string.settings_build_info,
                            BuildConfig.APPLICATION_ID,
                            BuildConfig.VERSION_CODE,
                        ),
                    )
                    Text(
                        text = stringResource(R.string.settings_description),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

@Composable
private fun SettingsSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    VeerCard(modifier = Modifier.fillMaxWidth()) {
        Text(text = title, style = MaterialTheme.typography.titleMedium)
        content()
    }
}

@Composable
private fun SettingsNavigationRow(
    title: String,
    summary: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    VeerSettingsRow(
        title = title,
        description = summary,
        enabled = enabled,
        onClick = onClick,
        trailingContent = {
            Text(
                text = stringResource(
                    if (enabled) R.string.common_enter else R.string.common_unavailable,
                ),
                color = if (enabled) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
        },
    )
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

private val PreviewBackgroundStatus = BackgroundRestrictionPolicy.evaluate(
    BackgroundRestrictionSignals(
        oemFamily = OemFamily.OTHER,
        batteryOptimizationExempt = true,
        backgroundRestricted = false,
        standbyBucket = AppStandbyBucket.ACTIVE,
        powerSaveMode = false,
    ),
)

@VeerThemePreviews
@Composable
private fun SettingsScreenPreview() {
    SettingsPreviewContent()
}

@VeerResponsivePreviews
@Composable
private fun SettingsScreenResponsivePreview() {
    SettingsPreviewContent(
        profileName = "Work, streaming, AI and international research subscription",
    )
}

@Composable
private fun SettingsPreviewContent(profileName: String = "Daily profile") {
    VeerPreview {
        SettingsScreen(
            activeProfileName = profileName,
            hasApiKey = true,
            perAppPolicy = PerAppProxyPolicy(),
            backgroundStatus = PreviewBackgroundStatus,
            themeMode = ThemeMode.SYSTEM,
            onBack = {},
            onSaveApiKey = {},
            onClearApiKey = {},
            onOpenDns = {},
            onOpenPerApp = {},
            onThemeModeChange = {},
            onOpenBatterySettings = {},
            onOpenAutoStartSettings = {},
            onOpenApplicationDetails = {},
        )
    }
}
