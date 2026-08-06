package com.yamax.veer.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.annotation.StringRes
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.StartupStage
import com.yamax.veer.ui.designsystem.components.VeerCard
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerSpacing

/**
 * Presentation model for the real startup stages emitted by the VPN service.
 *
 * Percentages are intentionally milestone based. They never imply that startup
 * duration can be estimated from a timer.
 */
internal data class StartupProgressUi(
    @param:StringRes val detailRes: Int,
    val step: Int,
    val totalSteps: Int,
    val progress: Float,
)

@Composable
internal fun StartupProgressPanel(stage: StartupStage) {
    val model = startupProgressUi(stage)

    VeerCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("startup_progress_panel"),
        containerColor = MaterialTheme.colorScheme.secondaryContainer,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = stringResource(R.string.startup_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = stringResource(
                    R.string.startup_percent,
                    (model.progress * 100).toInt(),
                ),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.testTag("startup_progress_percent"),
            )
        }
        LinearProgressIndicator(
            progress = { model.progress },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("startup_progress_bar"),
        )
        Text(
            text = stringResource(
                R.string.startup_step,
                model.step,
                model.totalSteps,
                stringResource(model.detailRes),
            ),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.testTag("startup_progress_detail"),
        )
    }
}

@VeerThemePreviews
@Composable
private fun StartupProgressPanelPreview() {
    VeerPreview {
        Column(
            modifier = Modifier.padding(VeerSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
        ) {
            StartupProgressPanel(StartupStage.ENSURING_GEO_DATA)
            StartupProgressPanel(StartupStage.READY)
        }
    }
}

internal fun startupProgressUi(stage: StartupStage): StartupProgressUi = when (stage) {
    StartupStage.IDLE -> StartupProgressUi(
        detailRes = R.string.startup_waiting,
        step = 0,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0f,
    )
    StartupStage.PREPARING_CONFIG -> StartupProgressUi(
        detailRes = R.string.startup_preparing_config,
        step = 1,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0.1f,
    )
    StartupStage.ENSURING_GEO_DATA -> StartupProgressUi(
        detailRes = R.string.startup_checking_data,
        step = 2,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0.3f,
    )
    StartupStage.VALIDATING_CONFIG -> StartupProgressUi(
        detailRes = R.string.startup_validating_config,
        step = 3,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0.5f,
    )
    StartupStage.ESTABLISHING_TUNNEL -> StartupProgressUi(
        detailRes = R.string.startup_establishing_tunnel,
        step = 4,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0.7f,
    )
    StartupStage.STARTING_RUNTIME -> StartupProgressUi(
        detailRes = R.string.startup_starting_mihomo,
        step = 5,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0.82f,
    )
    StartupStage.VERIFYING_RUNTIME -> StartupProgressUi(
        detailRes = R.string.startup_verifying_mihomo,
        step = 6,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 0.94f,
    )
    StartupStage.READY -> StartupProgressUi(
        detailRes = R.string.startup_ready,
        step = STARTUP_STEP_COUNT,
        totalSteps = STARTUP_STEP_COUNT,
        progress = 1f,
    )
}

private const val STARTUP_STEP_COUNT = 6
