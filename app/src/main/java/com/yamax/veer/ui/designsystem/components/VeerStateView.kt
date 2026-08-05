package com.yamax.veer.ui.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerSpacing

@Composable
fun VeerStateView(
    title: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    iconContentDescription: String? = null,
    description: String? = null,
    actionText: String? = null,
    onAction: (() -> Unit)? = null,
    loading: Boolean = false,
) {
    Column(
        modifier = modifier.padding(VeerSpacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VeerSpacing.md),
    ) {
        when {
            loading -> CircularProgressIndicator(modifier = Modifier.size(VeerDimensions.stateIcon))
            icon != null -> Icon(
                imageVector = icon,
                contentDescription = iconContentDescription,
                modifier = Modifier.size(VeerDimensions.stateIcon),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            textAlign = TextAlign.Center,
        )
        if (description != null) {
            Text(
                text = description,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
            )
        }
        if (actionText != null && onAction != null) {
            VeerPrimaryButton(text = actionText, onClick = onAction)
        }
    }
}

@VeerThemePreviews
@Composable
private fun VeerStateViewPreview() {
    VeerPreview {
        Column(modifier = Modifier.fillMaxWidth()) {
            VeerStateView(
                icon = Icons.Default.Info,
                title = "No profiles yet",
                description = "Import a subscription or local YAML file to get started.",
                actionText = "Import profile",
                onAction = {},
            )
            VeerStateView(title = "Loading nodes", loading = true)
        }
    }
}
