package com.yamax.veer.ui.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerAlpha
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import com.yamax.veer.ui.designsystem.theme.veerColors

enum class VeerStatus {
    Connected,
    Connecting,
    Disconnected,
    Unavailable,
    Warning,
    Loading,
}

@Composable
fun VeerStatusBadge(
    status: VeerStatus,
    label: String,
    modifier: Modifier = Modifier,
) {
    val colors = statusColors(status)
    Row(
        modifier = modifier
            .background(colors.container, VeerShapes.pill)
            .padding(horizontal = VeerSpacing.md, vertical = VeerSpacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (status == VeerStatus.Loading || status == VeerStatus.Connecting) {
            CircularProgressIndicator(
                modifier = Modifier.size(VeerDimensions.iconSmall),
                color = colors.content,
                strokeWidth = VeerDimensions.progressStroke,
            )
        } else {
            Box(
                modifier = Modifier
                    .size(VeerSpacing.sm)
                    .background(colors.content, VeerShapes.pill),
            )
        }
        Text(text = label, color = colors.content, style = MaterialTheme.typography.labelMedium)
    }
}

private data class StatusColors(val container: Color, val content: Color)

@Composable
private fun statusColors(status: VeerStatus): StatusColors {
    val extended = MaterialTheme.veerColors
    val content = when (status) {
        VeerStatus.Connected -> extended.connected
        VeerStatus.Connecting, VeerStatus.Loading -> extended.connecting
        VeerStatus.Disconnected -> extended.disconnected
        VeerStatus.Unavailable -> MaterialTheme.colorScheme.onSurfaceVariant
        VeerStatus.Warning -> extended.warning
    }
    return StatusColors(
        container = content.copy(alpha = VeerAlpha.disabledContainer),
        content = content,
    )
}

@VeerThemePreviews
@Composable
private fun VeerStatusBadgePreview() {
    VeerPreview {
        Row(
            modifier = Modifier.padding(VeerSpacing.lg),
            horizontalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
        ) {
            VeerStatusBadge(status = VeerStatus.Connected, label = "Connected")
            VeerStatusBadge(status = VeerStatus.Connecting, label = "Connecting")
            VeerStatusBadge(status = VeerStatus.Warning, label = "Attention")
        }
    }
}
