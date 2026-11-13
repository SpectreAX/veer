package com.yamax.veer.ui.designsystem.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerShapes

@Composable
fun VeerDialog(
    title: String,
    body: String,
    confirmText: String,
    onConfirm: () -> Unit,
    dismissText: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            VeerPrimaryButton(text = confirmText, onClick = onConfirm)
        },
        dismissButton = {
            VeerSecondaryButton(text = dismissText, onClick = onDismiss)
        },
        modifier = modifier,
        shape = VeerShapes.extraLarge,
    )
}

@VeerThemePreviews
@Composable
private fun VeerDialogPreview() {
    VeerPreview {
        VeerDialog(
            title = "Delete rule?",
            body = "This change updates the active connection immediately.",
            confirmText = "Delete",
            onConfirm = {},
            dismissText = "Cancel",
            onDismiss = {},
        )
    }
}
