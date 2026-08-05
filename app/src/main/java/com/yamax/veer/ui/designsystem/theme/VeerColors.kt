package com.yamax.veer.ui.designsystem.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

internal val VeerLightColorScheme = lightColorScheme(
    primary = Color(0xFF426900),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFB7F34A),
    onPrimaryContainer = Color(0xFF172700),
    secondary = Color(0xFF56634A),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFDAE8C9),
    onSecondaryContainer = Color(0xFF141F0D),
    tertiary = Color(0xFF386663),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFBCECE7),
    onTertiaryContainer = Color(0xFF00201E),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = Color(0xFFFAFDF5),
    onBackground = Color(0xFF1A1C17),
    surface = Color(0xFFFAFDF5),
    onSurface = Color(0xFF1A1C17),
    surfaceVariant = Color(0xFFE1E4D8),
    onSurfaceVariant = Color(0xFF45483F),
    surfaceContainer = Color(0xFFEEF1E9),
    surfaceContainerHigh = Color(0xFFE8EBE3),
    surfaceContainerHighest = Color(0xFFE2E5DD),
    outline = Color(0xFF75786E),
    outlineVariant = Color(0xFFC5C8BD),
)

internal val VeerDarkColorScheme = darkColorScheme(
    primary = Color(0xFFB7F34A),
    onPrimary = Color(0xFF203600),
    primaryContainer = Color(0xFF304F00),
    onPrimaryContainer = Color(0xFFD0FF7B),
    secondary = Color(0xFFBECBAE),
    onSecondary = Color(0xFF29341F),
    secondaryContainer = Color(0xFF3F4B35),
    onSecondaryContainer = Color(0xFFDAE8C9),
    tertiary = Color(0xFFA0D0CB),
    onTertiary = Color(0xFF003734),
    tertiaryContainer = Color(0xFF1E4E4B),
    onTertiaryContainer = Color(0xFFBCECE7),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF10140F),
    onBackground = Color(0xFFE1E4DC),
    surface = Color(0xFF10140F),
    onSurface = Color(0xFFE1E4DC),
    surfaceVariant = Color(0xFF45483F),
    onSurfaceVariant = Color(0xFFC5C8BD),
    surfaceContainer = Color(0xFF1C201A),
    surfaceContainerHigh = Color(0xFF262A24),
    surfaceContainerHighest = Color(0xFF31352E),
    outline = Color(0xFF8F9287),
    outlineVariant = Color(0xFF45483F),
)

@Immutable
data class VeerExtendedColors(
    val connected: Color,
    val onConnected: Color,
    val connecting: Color,
    val onConnecting: Color,
    val disconnected: Color,
    val onDisconnected: Color,
    val warning: Color,
    val onWarning: Color,
)

internal val VeerLightExtendedColors = VeerExtendedColors(
    connected = Color(0xFF356A1C),
    onConnected = Color(0xFFFFFFFF),
    connecting = Color(0xFF765900),
    onConnecting = Color(0xFFFFFFFF),
    disconnected = Color(0xFF5F6259),
    onDisconnected = Color(0xFFFFFFFF),
    warning = Color(0xFF8A5100),
    onWarning = Color(0xFFFFFFFF),
)

internal val VeerDarkExtendedColors = VeerExtendedColors(
    connected = Color(0xFFA1D889),
    onConnected = Color(0xFF0B3900),
    connecting = Color(0xFFFFD75D),
    onConnecting = Color(0xFF3E2E00),
    disconnected = Color(0xFFC8CBC1),
    onDisconnected = Color(0xFF30332C),
    warning = Color(0xFFFFB95F),
    onWarning = Color(0xFF492900),
)

internal val LocalVeerExtendedColors = staticCompositionLocalOf {
    VeerLightExtendedColors
}
