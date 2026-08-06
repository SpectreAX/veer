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
import com.yamax.veer.ui.profile.ProfileDetailContent
import com.yamax.veer.ui.profile.ProfileDetailViewModel
import com.yamax.veer.core_compatibility.AppStandbyBucket
import com.yamax.veer.core_compatibility.BackgroundRestrictionPolicy
import com.yamax.veer.core_compatibility.BackgroundRestrictionSignals
import com.yamax.veer.core_compatibility.OemFamily
import com.yamax.veer.data.PerAppProxyPolicy
import com.yamax.veer.ui.settings.SettingsScreen
import com.yamax.veer.ui.logs.LogSource
import com.yamax.veer.ui.logs.LogViewerScreen
import com.yamax.veer.ui.logs.LogViewerUiState
import com.yamax.veer.ui.logs.ViewerLogLevel
import com.yamax.veer.ui.logs.ViewerLogLine
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.ui.connections.ConnectionsScreen
import com.yamax.veer.ui.connections.ConnectionsUiState
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.rules.RulesScreen
import com.yamax.veer.ui.rules.RulesUiState
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.ui.dns.DnsSettingsScreen
import com.yamax.veer.ui.dns.DnsSettingsUiState
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.ui.perapp.InstalledAppEntry
import com.yamax.veer.ui.perapp.PerAppProxyScreen
import com.yamax.veer.ui.perapp.PerAppProxyUiState
import com.yamax.veer.ui.theme.ThemeMode
import com.yamax.veer.ui.theme.VeerTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import com.yamax.veer.core_mihomo.StartupStage
import com.yamax.veer.data.AiHistoryEntry
import com.yamax.veer.data.AiHistoryMutation
import com.yamax.veer.data.AiHistoryRuleStore
import com.yamax.veer.data.AiHistorySource
import com.yamax.veer.data.AiHistoryStatus
import com.yamax.veer.data.SpeedSample
import com.yamax.veer.ui.StartupProgressPanel
import com.yamax.veer.ui.ai.AiHistorySection
import com.yamax.veer.ui.chart.SpeedChart
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.components.VeerTopAppBar
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.navigation.VeerBottomBar
import com.yamax.veer.ui.navigation.VeerTopLevelDestination

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
                    SCREEN_LOGS -> LogsReviewScreen()
                    SCREEN_CONNECTIONS -> ConnectionsReviewScreen()
                    SCREEN_PROFILE_DETAIL -> ProfileDetailReviewScreen()
                    SCREEN_RULES -> RulesReviewScreen()
                    SCREEN_DNS -> DnsReviewScreen()
                    SCREEN_PER_APP -> PerAppReviewScreen()
                    SCREEN_EMBEDDED -> EmbeddedComponentsReviewScreen()
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
        const val SCREEN_LOGS = "logs"
        const val SCREEN_CONNECTIONS = "connections"
        const val SCREEN_PROFILE_DETAIL = "profile-detail"
        const val SCREEN_RULES = "rules"
        const val SCREEN_DNS = "dns"
        const val SCREEN_PER_APP = "per-app"
        const val SCREEN_EMBEDDED = "embedded"
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
        showBackNavigation = false,
        bottomBar = {
            VeerBottomBar(selected = VeerTopLevelDestination.NODES, onSelect = {})
        },
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
        showBackNavigation = false,
        bottomBar = {
            VeerBottomBar(selected = VeerTopLevelDestination.PROFILES, onSelect = {})
        },
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
        showBackNavigation = false,
        bottomBar = {
            VeerBottomBar(selected = VeerTopLevelDestination.SETTINGS, onSelect = {})
        },
    )
}

@androidx.compose.runtime.Composable
private fun LogsReviewScreen() {
    LogViewerScreen(
        state = LogViewerUiState(
            lines = listOf(
                ViewerLogLine(
                    id = "review-error",
                    time = "10:42:08.271",
                    source = LogSource.CORE,
                    level = ViewerLogLevel.ERROR,
                    category = "connection",
                    message = "Could not reach the selected proxy. Existing traffic remains protected.",
                ),
                ViewerLogLine(
                    id = "review-warning",
                    time = "10:42:07.119",
                    source = LogSource.UI,
                    level = ViewerLogLevel.WARN,
                    category = "route-check-with-a-very-long-category-name",
                    message = "Latency is higher than usual for the selected streaming route. " +
                        "This deliberately long entry verifies wrapping on narrow screens.",
                ),
                ViewerLogLine(
                    id = "review-info",
                    time = "10:42:06.004",
                    source = LogSource.CORE,
                    level = ViewerLogLevel.INFO,
                    category = "runtime",
                    message = "Proxy runtime started successfully.",
                ),
            ),
        ),
        onBack = {}, onQueryChange = {}, onSourceChange = {}, onLevelChange = {},
        onTogglePaused = {}, onRefresh = {}, onCopy = {}, onExport = {},
    )
}

@androidx.compose.runtime.Composable
private fun ConnectionsReviewScreen() {
    val connections = listOf(
        MihomoRepository.ConnectionInfo(
            id = "review-stream",
            host = "very-long-streaming-service.example.com",
            destinationIP = "203.0.113.42",
            network = "tcp",
            type = "HTTPS",
            chains = listOf("Japan Tokyo premium streaming and AI route"),
            rule = "Netflix and streaming services",
            rulePayload = "",
            download = 84L * 1024L * 1024L,
            upload = 3L * 1024L * 1024L,
            start = "",
        ),
        MihomoRepository.ConnectionInfo(
            id = "review-direct",
            host = "updates.example.org",
            destinationIP = "198.51.100.8",
            network = "udp",
            type = "QUIC",
            chains = emptyList(),
            rule = "DIRECT",
            rulePayload = "",
            download = 512L * 1024L,
            upload = 48L * 1024L,
            start = "",
        ),
    )
    ConnectionsScreen(
        state = ConnectionsUiState(
            connections = connections,
            filteredConnections = connections,
            loading = false,
            running = true,
        ),
        onBack = {}, onSearch = {}, onSort = {}, onCloseConnection = {},
        onCloseAll = {}, onDismissMessage = {},
    )
}

@androidx.compose.runtime.Composable
private fun ProfileDetailReviewScreen() {
    val metadata = ProfileMetadata(
        id = ProfileId("profile-detail-review"),
        displayName = "Work, streaming and AI subscription with a long profile name",
        source = ProfileSource.SubscriptionUrl(
            url = "https://example.com/subscription",
            lastFetchedMs = 1_700_000_000_000,
        ),
        importedAtMs = 1_700_000_000_000,
        lastUpdatedMs = 1_700_000_000_000,
        proxyCount = 5,
        groupCount = 2,
        ruleCount = 520,
        rawSizeBytes = 65_536,
        configHashSha256 = "review",
    )
    val groups = listOf(
        ProfileDetailViewModel.ProxyGroupUi(
            name = "Streaming, AI and international services",
            type = "select",
            proxies = listOf(
                "Japan Tokyo premium streaming and AI route",
                "Hong Kong 02",
                "United States West 03",
            ),
            selected = "Japan Tokyo premium streaming and AI route",
        ),
        ProfileDetailViewModel.ProxyGroupUi(
            name = "Fallback",
            type = "url-test",
            proxies = listOf("Automatic low-latency route", "Direct"),
            selected = "Automatic low-latency route",
        ),
    )
    ProfileDetailContent(
        state = ProfileDetailViewModel.UiState(
            metadata = metadata,
            proxyGroups = groups,
            isLoading = false,
            vpnRunning = true,
        ),
        onBack = {},
        onSelect = { _, _ -> },
    )
}

@androidx.compose.runtime.Composable
private fun RulesReviewScreen() {
    val rules = listOf(
        ManagedAiRule(
            id = "review-netflix",
            raw = "GEOSITE,netflix,Japan Tokyo premium streaming and AI route",
            matchType = "GEOSITE",
            target = "netflix",
            policy = "Japan Tokyo premium streaming and AI route",
            enabled = true,
            policyAvailable = true,
            loadedInMaterializedConfig = true,
        ),
        ManagedAiRule(
            id = "review-chatgpt",
            raw = "DOMAIN-SUFFIX,openai.com,United States West 03",
            matchType = "DOMAIN-SUFFIX",
            target = "openai.com",
            policy = "United States West 03",
            enabled = false,
            policyAvailable = true,
            loadedInMaterializedConfig = false,
        ),
    )
    RulesScreen(
        state = RulesUiState(
            profileName = "Work, streaming and AI subscription with a long profile name",
            profileId = "review",
            rules = rules,
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
        showBackNavigation = false,
        bottomBar = {
            VeerBottomBar(selected = VeerTopLevelDestination.RULES, onSelect = {})
        },
    )
}

@androidx.compose.runtime.Composable
private fun DnsReviewScreen() {
    DnsSettingsScreen(
        state = DnsSettingsUiState(
            loading = false,
            profileId = ProfileId("dns-review"),
            profileName = "Work, streaming and AI subscription with a long profile name",
            isActiveProfile = true,
            runtimeState = EngineState.Running,
            policy = DnsOverridePolicy(
                mode = DnsOverrideMode.CUSTOM,
                ipv6 = true,
                enhancedMode = DnsEnhancedMode.FAKE_IP,
                defaultNameservers = listOf("223.5.5.5", "1.1.1.1"),
                nameservers = listOf(
                    "https://1.1.1.1/dns-query",
                    "https://cloudflare-dns.com/dns-query",
                ),
                fallbackNameservers = listOf("tls://dns.google"),
            ),
        ),
        onBack = {}, onModeChange = {}, onIpv6Change = {},
        onEnhancedModeChange = {}, onDefaultNameserversChange = {},
        onNameserversChange = {}, onFallbackNameserversChange = {},
        onSave = {}, onDismissMessage = {},
    )
}

@androidx.compose.runtime.Composable
private fun PerAppReviewScreen() {
    PerAppProxyScreen(
        state = PerAppProxyUiState(
            loading = false,
            mode = PerAppProxyMode.ONLY_SELECTED,
            selectedPackages = setOf("com.example.streaming", "com.example.removed"),
            apps = listOf(
                InstalledAppEntry(
                    label = "Streaming application with a deliberately long localized name",
                    packageName = "com.example.streaming",
                    isSystemApp = false,
                ),
                InstalledAppEntry(
                    label = "System browser",
                    packageName = "com.example.browser.system",
                    isSystemApp = true,
                ),
                InstalledAppEntry(
                    label = "com.example.removed",
                    packageName = "com.example.removed",
                    isSystemApp = false,
                    isAvailable = false,
                ),
            ),
        ),
        runtimeRunning = true,
        onBack = {}, onRetry = {}, onModeChange = {}, onTogglePackage = {},
        onSelectVisible = {}, onClearSelection = {}, onSave = {}, onDismissMessage = {},
    )
}

@androidx.compose.runtime.Composable
private fun EmbeddedComponentsReviewScreen() {
    val history = listOf(
        AiHistoryEntry(
            id = "embedded-success",
            profileId = "active",
            prompt = "Route Netflix and Japanese streaming through the lowest-latency Japan node",
            source = AiHistorySource.LOCAL,
            status = AiHistoryStatus.SUCCESS,
            timestampMs = 1_700_000_000_000,
            summary = "Netflix exits through Japan Tokyo premium streaming and AI route.",
            generatedRules = listOf(
                "GEOSITE,netflix,Japan Tokyo premium streaming and AI route",
            ),
            mutation = AiHistoryMutation(
                rulesBefore = AiHistoryRuleStore(emptyList(), emptyList()),
                rulesAfter = AiHistoryRuleStore(
                    enabled = listOf("GEOSITE,netflix,Japan Tokyo premium streaming and AI route"),
                    disabled = emptyList(),
                ),
            ),
        ),
        AiHistoryEntry(
            id = "embedded-failure",
            profileId = "other-profile",
            prompt = "ChatGPT go us",
            source = AiHistorySource.LLM,
            status = AiHistoryStatus.FAILURE,
            timestampMs = 1_700_000_060_000,
            summary = "No available United States route was found. Existing traffic was unchanged.",
        ),
    )
    Scaffold(
        topBar = { VeerTopAppBar(title = "Embedded status components") },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(VeerSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.lg),
        ) {
            item {
                StartupProgressPanel(StartupStage.ENSURING_GEO_DATA)
            }
            item {
                VeerCard(modifier = Modifier.fillMaxWidth()) {
                    SpeedChart(
                        history = listOf(
                            SpeedSample(1, 32_768, 120_000),
                            SpeedSample(2, 64_000, 800_000),
                            SpeedSample(3, 48_000, 360_000),
                            SpeedSample(4, 96_000, 1_200_000),
                        ),
                        connected = true,
                    )
                }
            }
            item {
                AiHistorySection(
                    entries = history,
                    activeProfileId = "active",
                    busy = false,
                    onReplay = {},
                    onUndo = {},
                )
            }
        }
    }
}
