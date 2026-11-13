package com.yamax.veer.ui.designsystem.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import com.yamax.veer.ui.theme.ThemeMode
import com.yamax.veer.ui.theme.ThemePreference
import com.yamax.veer.ui.theme.resolveDarkTheme

@Composable
fun VeerDesignSystemTheme(
    themeMode: ThemeMode? = null,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val preferredMode by ThemePreference.mode.collectAsState()
    val darkTheme = resolveDarkTheme(
        mode = themeMode ?: preferredMode,
        systemDark = isSystemInDarkTheme(),
    )
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }

        darkTheme -> VeerDarkColorScheme
        else -> VeerLightColorScheme
    }
    val extendedColors = if (darkTheme) VeerDarkExtendedColors else VeerLightExtendedColors

    CompositionLocalProvider(LocalVeerExtendedColors provides extendedColors) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = VeerTypography,
            shapes = androidx.compose.material3.Shapes(
                extraSmall = VeerShapes.small,
                small = VeerShapes.small,
                medium = VeerShapes.medium,
                large = VeerShapes.large,
                extraLarge = VeerShapes.extraLarge,
            ),
            content = content,
        )
    }
}

val MaterialTheme.veerColors: VeerExtendedColors
    @Composable
    @ReadOnlyComposable
    get() = LocalVeerExtendedColors.current
