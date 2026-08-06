package com.yamax.veer.ui.designsystem.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerElevation
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing

@Composable
fun VeerCard(
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainer,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.then(
            if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick)
            else Modifier,
        ),
        shape = VeerShapes.large,
        color = containerColor,
        tonalElevation = VeerElevation.none,
    ) {
        Column(
            modifier = Modifier.padding(VeerSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.sm),
            content = content,
        )
    }
}

@VeerThemePreviews
@Composable
private fun VeerCardPreview() {
    VeerPreview {
        VeerCard(
            modifier = Modifier
                .fillMaxWidth()
                .padding(VeerSpacing.lg),
        ) {
            Text("Current route", style = MaterialTheme.typography.titleMedium)
            Text(
                "Proxy · Tokyo 01",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}
