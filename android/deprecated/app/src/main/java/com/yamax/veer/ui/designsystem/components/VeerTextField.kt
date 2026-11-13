package com.yamax.veer.ui.designsystem.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerShapes
import com.yamax.veer.ui.designsystem.theme.VeerSpacing

@Composable
fun VeerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    supportingText: String? = null,
    errorText: String? = null,
    enabled: Boolean = true,
    singleLine: Boolean = false,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: (@Composable () -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        label = { Text(label) },
        placeholder = placeholder?.let { value -> { Text(value) } },
        supportingText = (errorText ?: supportingText)?.let { value ->
            {
                Text(
                    text = value,
                    color = if (errorText != null) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
        },
        isError = errorText != null,
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        shape = VeerShapes.medium,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        visualTransformation = visualTransformation,
        trailingIcon = trailingIcon,
    )
}

/** TextFieldValue overload for IMEs that maintain an active composition range. */
@Composable
fun VeerTextField(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    supportingText: String? = null,
    errorText: String? = null,
    enabled: Boolean = true,
    singleLine: Boolean = false,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: (@Composable () -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        label = { Text(label) },
        placeholder = placeholder?.let { placeholderValue -> { Text(placeholderValue) } },
        supportingText = (errorText ?: supportingText)?.let { supportingValue ->
            {
                Text(
                    text = supportingValue,
                    color = if (errorText != null) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
        },
        isError = errorText != null,
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        shape = VeerShapes.medium,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        visualTransformation = visualTransformation,
        trailingIcon = trailingIcon,
    )
}

@VeerThemePreviews
@Composable
private fun VeerTextFieldPreview() {
    VeerPreview {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(VeerSpacing.lg),
        ) {
            VeerTextField(
                value = "",
                onValueChange = {},
                label = "Subscription URL",
                placeholder = "https://example.com/subscription",
                supportingText = "The address is stored only on this device.",
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            VeerTextField(
                value = "invalid",
                onValueChange = {},
                label = "API key",
                errorText = "Enter a valid key.",
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
