package com.yamax.veer.ui.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing

@Composable
fun VeerPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    leadingContent: (@Composable RowScope.() -> Unit)? = null,
) {
    Button(
        onClick = onClick,
        modifier = modifier.heightIn(min = VeerDimensions.touchTarget),
        enabled = enabled && !loading,
        shape = VeerShapes.medium,
    ) {
        VeerButtonContent(text = text, loading = loading, leadingContent = leadingContent)
    }
}

@Composable
fun VeerSecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    leadingContent: (@Composable RowScope.() -> Unit)? = null,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.heightIn(min = VeerDimensions.touchTarget),
        enabled = enabled && !loading,
        shape = VeerShapes.medium,
    ) {
        VeerButtonContent(text = text, loading = loading, leadingContent = leadingContent)
    }
}

@Composable
private fun RowScope.VeerButtonContent(
    text: String,
    loading: Boolean,
    leadingContent: (@Composable RowScope.() -> Unit)?,
) {
    if (loading) {
        CircularProgressIndicator(
            modifier = Modifier
                .padding(end = VeerSpacing.sm)
                .size(VeerDimensions.iconSmall),
            color = MaterialTheme.colorScheme.onSurface,
            strokeWidth = VeerDimensions.progressStroke,
        )
    } else if (leadingContent != null) {
        leadingContent()
    }
    Text(text = text, style = MaterialTheme.typography.labelLarge)
}

@VeerThemePreviews
@Composable
private fun VeerButtonPreview() {
    VeerPreview {
        Column(
            modifier = Modifier.padding(VeerSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            VeerPrimaryButton(text = "Connect", onClick = {}, modifier = Modifier.fillMaxWidth())
            VeerPrimaryButton(
                text = "Connecting",
                onClick = {},
                loading = true,
                modifier = Modifier.fillMaxWidth(),
            )
            VeerSecondaryButton(text = "View details", onClick = {}, enabled = false)
        }
    }
}
