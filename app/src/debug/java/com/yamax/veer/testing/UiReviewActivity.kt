package com.yamax.veer.testing

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.yamax.veer.ui.nodes.NodeFilter
import com.yamax.veer.ui.nodes.NodeUi
import com.yamax.veer.ui.nodes.NodesScreen
import com.yamax.veer.ui.nodes.NodesUiState
import com.yamax.veer.ui.nodes.ProxyGroupUi
import com.yamax.veer.core_profile.ImportState
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.ui.profile.ProfileListActions
import com.yamax.veer.ui.profile.ProfileListContent
import com.yamax.veer.ui.profile.ProfileListViewModel
import com.yamax.veer.core_compatibility.AppStandbyBucket
import com.yamax.veer.core_compatibility.BackgroundRestrictionPolicy
import com.yamax.veer.core_compatibility.BackgroundRestrictionSignals
import com.yamax.veer.core_compatibility.OemFamily
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.ui.settings.SettingsScreen
import com.yamax.veer.ui.theme.ThemeMode
import com.yamax.veer.ui.theme.VeerTheme

/** Debug-only host for deterministic runtime screenshots of real feature screens. */
class UiReviewActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                when (intent.getStringExtra(EXTRA_SCREEN)) {
                    SCREEN_NODES -> NodesReviewScreen()
                    SCREEN_PROFILES -> ProfilesReviewScreen()
                    SCREEN_SETTINGS -> SettingsReviewScreen()
                    else -> NodesReviewScreen()
                }
            }
        }
    }

    companion object {
        const val EXTRA_SCREEN = "screen"
        const val SCREEN_NODES = "nodes"
        const val SCREEN_PROFILES = "profiles"
        const val SCREEN_SETTINGS = "settings"
    }
}

@androidx.compose.runtime.Composable
private fun NodesReviewScreen() {
    val selectedNode = "Japan Tokyo premium streaming and AI route"
    val groups = listOf(
        ProxyGroupUi(
            name = "Streaming and AI",
            type = "Selector",
            selected = selectedNode,
            selectable = true,
            nodes = listOf(
                NodeUi(selectedNode, "VLESS", "JP", 42, true, true),
                NodeUi("Hong Kong 02", "Trojan", "HK", 238, true, false),
                NodeUi("United States unavailable 03", "Shadowsocks", "US", 65_535, false, false),
            ),
        ),
    )
    NodesScreen(
        state = NodesUiState(groups = groups, running = true, loading = false),
        filter = NodeFilter(),
        availableRegions = listOf("JP", "HK", "US"),
        filteredGroups = groups,
        onBack = ::finishReview,
        onRefresh = {},
        onProbeAll = {},
        onSelect = { _, _ -> },
        onAutoSelect = {},
        onProbe = {},
        onDismissMessage = {},
        onUpdateSortMode = {},
        onUpdateRegionFilter = {},
        onToggleHideUnavailable = {},
        onClearFilters = {},
    )
}

private fun finishReview() = Unit

@androidx.compose.runtime.Composable
private fun ProfilesReviewScreen() {
    val profile = ProfileMetadata(
        id = ProfileId("ui-review-profile"),
        displayName = "Work, streaming and AI subscription",
        source = ProfileSource.SubscriptionUrl(
            url = "https://example.com/subscription",
            lastFetchedMs = 1_700_000_000_000,
        ),
        importedAtMs = 1_700_000_000_000,
        lastUpdatedMs = 1_700_000_000_000,
        proxyCount = 24,
        groupCount = 7,
        ruleCount = 520,
        rawSizeBytes = 65_536,
        configHashSha256 = "ui-review",
    )
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
        actions = ProfileListActions(
            onBack = {}, onRefreshAll = {}, onImportUrl = {}, onPasteUrl = {}, onSelectFile = {},
            onImportYaml = {}, onClearImportState = {}, onDismissError = {},
            onActivate = {}, onDetails = {}, onDns = {}, onRefresh = {}, onEdit = {},
            onDelete = {}, onDismissEdit = {}, onUpdateEditName = {}, onSubmitEdit = {},
            onDismissDelete = {}, onConfirmDelete = {},
        ),
    )
}

@androidx.compose.runtime.Composable
private fun SettingsReviewScreen() {
    val backgroundStatus = BackgroundRestrictionPolicy.evaluate(
        BackgroundRestrictionSignals(
            oemFamily = OemFamily.XIAOMI,
            batteryOptimizationExempt = false,
            backgroundRestricted = false,
            standbyBucket = AppStandbyBucket.ACTIVE,
            powerSaveMode = false,
        ),
    )
    SettingsScreen(
        activeProfileName = "Work, streaming and AI subscription",
        hasApiKey = true,
        perAppPolicy = PerAppProxyPolicy(),
        backgroundStatus = backgroundStatus,
        themeMode = ThemeMode.SYSTEM,
        onBack = {}, onSaveApiKey = {}, onClearApiKey = {}, onOpenDns = {},
        onOpenPerApp = {}, onThemeModeChange = {}, onOpenBatterySettings = {},
        onOpenAutoStartSettings = {}, onOpenApplicationDetails = {},
    )
}
