package com.yamax.veer.ui.theme

import androidx.compose.runtime.Composable
import com.yamax.veer.ui.designsystem.theme.VeerDesignSystemTheme

@Composable
fun VeerTheme(
    themeMode: ThemeMode? = null,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    VeerDesignSystemTheme(
        themeMode = themeMode,
        dynamicColor = dynamicColor,
        content = content,
    )
}
