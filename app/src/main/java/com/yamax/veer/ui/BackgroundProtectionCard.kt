package com.yamax.veer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.annotation.StringRes
import com.yamax.veer.R
import com.yamax.veer.core_compatibility.BackgroundRestrictionReason
import com.yamax.veer.core_compatibility.BackgroundRestrictionStatus
import com.yamax.veer.core_compatibility.BackgroundRisk

@Composable
fun BackgroundProtectionCard(
    status: BackgroundRestrictionStatus,
    onOpenBatterySettings: () -> Unit,
    onOpenAutoStartSettings: () -> Unit,
    onOpenApplicationDetails: () -> Unit,
    modifier: Modifier = Modifier,
    alwaysShow: Boolean = false,
) {
    if (!alwaysShow && !status.shouldShow) return

    var expanded by remember(status.risk, status.reasons) {
        mutableStateOf(status.risk == BackgroundRisk.RESTRICTED)
    }
    val containerColor = when (status.risk) {
        BackgroundRisk.RESTRICTED -> MaterialTheme.colorScheme.errorContainer
        BackgroundRisk.ATTENTION -> MaterialTheme.colorScheme.secondaryContainer
        BackgroundRisk.READY -> MaterialTheme.colorScheme.surfaceVariant
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("background_protection_card")
            .background(containerColor)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.background_protection_title),
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = stringResource(status.summaryRes()),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            TextButton(onClick = { expanded = !expanded }) {
                Text(
                    stringResource(
                        if (expanded) R.string.common_collapse else R.string.common_check,
                    ),
                )
            }
        }

        if (expanded) {
            status.reasons.forEach { reason ->
                Text(
                    text = stringResource(
                        R.string.background_reason_bullet,
                        stringResource(reason.userMessageRes()),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Text(
                text = stringResource(R.string.background_protection_disclaimer),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(
                onClick = onOpenBatterySettings,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.background_battery_settings))
            }
            if (status.needsOemReview) {
                OutlinedButton(
                    onClick = onOpenAutoStartSettings,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.background_autostart_settings))
                }
            }
            TextButton(
                onClick = onOpenApplicationDetails,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.background_app_details))
            }
        }
    }
}

@StringRes
private fun BackgroundRestrictionStatus.summaryRes(): Int = when (risk) {
    BackgroundRisk.RESTRICTED -> R.string.background_summary_restricted
    BackgroundRisk.ATTENTION -> when {
        needsOemReview && batteryOptimizationExempt ->
            R.string.background_summary_xiaomi_exempt
        needsOemReview ->
            R.string.background_summary_xiaomi_attention
        else -> R.string.background_summary_attention
    }
    BackgroundRisk.READY -> R.string.background_summary_ready
}

@StringRes
private fun BackgroundRestrictionReason.userMessageRes(): Int = when (this) {
    BackgroundRestrictionReason.SYSTEM_BACKGROUND_RESTRICTED ->
        R.string.background_reason_system_restricted
    BackgroundRestrictionReason.STANDBY_RESTRICTED ->
        R.string.background_reason_standby_restricted
    BackgroundRestrictionReason.STANDBY_RARE ->
        R.string.background_reason_standby_rare
    BackgroundRestrictionReason.BATTERY_OPTIMIZATION_ENABLED ->
        R.string.background_reason_battery_optimization
    BackgroundRestrictionReason.POWER_SAVE_MODE ->
        R.string.background_reason_power_save
    BackgroundRestrictionReason.XIAOMI_SETTINGS_UNVERIFIABLE ->
        R.string.background_reason_xiaomi_review
}
