package com.yamax.veer.ui

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/** A user-facing message that remains localizable while stored in UI state. */
internal sealed interface UiText {
    data class Resource(
        @param:StringRes val resourceId: Int,
        val arguments: List<Any> = emptyList(),
    ) : UiText

    data class Verbatim(val value: String) : UiText
}

internal fun uiText(@StringRes resourceId: Int, vararg arguments: Any): UiText =
    UiText.Resource(resourceId, arguments.toList())

@Composable
internal fun UiText.resolve(): String = resolve(LocalContext.current)

internal fun UiText.resolve(context: Context): String = when (this) {
    is UiText.Resource -> context.getString(
        resourceId,
        *arguments.map { argument ->
            if (argument is UiText) argument.resolve(context) else argument
        }.toTypedArray(),
    )
    is UiText.Verbatim -> value
}
