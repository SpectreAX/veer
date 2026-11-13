package com.yamax.veer.ui.profile

import android.app.Application
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
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.R
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.designsystem.components.VeerCard
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

@Composable
internal fun ProfileDetailScreen(
    profileId: ProfileId,
    onBack: () -> Unit,
) {
    val application = LocalContext.current.applicationContext as Application
    val factory = remember(profileId) {
        ProfileDetailViewModel.Factory(application, profileId)
    }
    val viewModel: ProfileDetailViewModel = viewModel(key = profileId.value, factory = factory)
    val state by viewModel.uiState.collectAsState()

    ProfileDetailContent(
        state = state,
        onBack = onBack,
        onSelect = viewModel::selectProxy,
    )
}

@Composable
internal fun ProfileDetailContent(
    state: ProfileDetailViewModel.UiState,
    onBack: () -> Unit,
    onSelect: (groupName: String, proxyName: String) -> Unit,
) {
    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("profile_detail_screen"),
        topBar = {
            VeerTopAppBar(
                title = state.metadata?.displayName
                    ?: stringResource(R.string.profile_fallback_title),
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
                state.isLoading -> VeerStateView(
                    title = stringResource(R.string.profile_detail_loading),
                    description = stringResource(R.string.profile_detail_loading_description),
                    loading = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = VeerDimensions.contentMaxWidth),
                )

                state.error != null -> VeerStateView(
                    icon = Icons.Default.Warning,
                    iconContentDescription = null,
                    title = stringResource(R.string.profile_detail_error_title),
                    description = state.error.resolve(),
                    actionText = stringResource(R.string.common_back),
                    onAction = onBack,
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = VeerDimensions.contentMaxWidth),
                )

                else -> ProfileDetailGroups(
                    state = state,
                    onSelect = onSelect,
                    modifier = Modifier
                        .fillMaxSize()
                        .widthIn(max = VeerDimensions.contentMaxWidth),
                )
            }
        }
    }
}

@Composable
private fun ProfileDetailGroups(
    state: ProfileDetailViewModel.UiState,
    onSelect: (groupName: String, proxyName: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        modifier = modifier.testTag("profile_detail_groups"),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            horizontal = VeerSpacing.lg,
            vertical = VeerSpacing.md,
        ),
        verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
    ) {
        item(key = "summary") {
            VeerCard(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    VeerStatusBadge(
                        status = if (state.vpnRunning) VeerStatus.Connected
                        else VeerStatus.Disconnected,
                        label = stringResource(
                            if (state.vpnRunning) R.string.profile_detail_runtime_live
                            else R.string.profile_detail_runtime_stopped,
                        ),
                    )
                    Text(
                        text = stringResource(
                            R.string.profile_detail_group_count,
                            state.proxyGroups.size,
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }

        if (!state.vpnRunning) {
            item(key = "stopped") {
                VeerCard(
                    modifier = Modifier.fillMaxWidth(),
                    containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(VeerSpacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        VeerStatusBadge(
                            status = VeerStatus.Warning,
                            label = stringResource(R.string.profile_detail_read_only),
                        )
                        Text(
                            text = stringResource(R.string.profile_vpn_stopped_detail),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        if (state.proxyGroups.isEmpty()) {
            item(key = "empty") {
                VeerStateView(
                    icon = Icons.Default.Info,
                    iconContentDescription = null,
                    title = stringResource(R.string.profile_detail_empty_title),
                    description = stringResource(R.string.profile_detail_empty_description),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        } else {
            items(state.proxyGroups, key = ProfileDetailViewModel.ProxyGroupUi::name) { group ->
                ProxyGroupCard(
                    group = group,
                    isSwitching = state.switchingGroup == group.name,
                    vpnRunning = state.vpnRunning,
                    onSelect = { proxyName -> onSelect(group.name, proxyName) },
                )
            }
        }
    }
}

@Composable
private fun ProxyGroupCard(
    group: ProfileDetailViewModel.ProxyGroupUi,
    isSwitching: Boolean,
    vpnRunning: Boolean,
    onSelect: (String) -> Unit,
) {
    val canSwitch = group.type.equals("select", ignoreCase = true) && vpnRunning && !isSwitching

    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("profile_group_${group.name}"),
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
            verticalAlignment = Alignment.Top,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs),
            ) {
                Text(
                    text = group.name,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = stringResource(R.string.profile_detail_node_count, group.proxies.size),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Column(
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs),
            ) {
                GroupTypeBadge(group.type)
                if (isSwitching) {
                    VeerStatusBadge(
                        status = VeerStatus.Loading,
                        label = stringResource(R.string.profile_switching),
                    )
                }
            }
        }

        group.proxies.forEach { proxyName ->
            val selected = group.selected == proxyName
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = VeerDimensions.touchTarget)
                    .then(
                        if (canSwitch) Modifier.clickable { onSelect(proxyName) }
                        else Modifier,
                    )
                    .padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xs),
                verticalArrangement = Arrangement.spacedBy(VeerSpacing.xs),
            ) {
                Text(
                    text = proxyName,
                    color = if (selected) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurface,
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (selected) {
                    VeerStatusBadge(
                        status = VeerStatus.Connected,
                        label = stringResource(R.string.profile_selected),
                    )
                }
            }
        }
    }
}

@Composable
private fun GroupTypeBadge(type: String) {
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
        shape = VeerShapes.pill,
    ) {
        Text(
            text = type,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xs),
        )
    }
}

private val PreviewProfileMetadata = ProfileMetadata(
    id = ProfileId("profile-detail-preview"),
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
    configHashSha256 = "preview",
)

private val PreviewProfileGroups = listOf(
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

@VeerThemePreviews
@Composable
private fun ProfileDetailNormalPreview() {
    VeerPreview {
        ProfileDetailContent(
            state = ProfileDetailViewModel.UiState(
                metadata = PreviewProfileMetadata,
                proxyGroups = PreviewProfileGroups,
                isLoading = false,
                vpnRunning = true,
            ),
            onBack = {},
            onSelect = { _, _ -> },
        )
    }
}

@VeerResponsivePreviews
@Composable
private fun ProfileDetailResponsivePreview() {
    VeerPreview {
        ProfileDetailContent(
            state = ProfileDetailViewModel.UiState(
                metadata = PreviewProfileMetadata,
                proxyGroups = PreviewProfileGroups,
                isLoading = false,
                vpnRunning = false,
            ),
            onBack = {},
            onSelect = { _, _ -> },
        )
    }
}

@VeerThemePreviews
@Composable
private fun ProfileDetailErrorPreview() {
    VeerPreview {
        ProfileDetailContent(
            state = ProfileDetailViewModel.UiState(
                isLoading = false,
                error = UiText.Verbatim("The saved profile data could not be read."),
            ),
            onBack = {},
            onSelect = { _, _ -> },
        )
    }
}
