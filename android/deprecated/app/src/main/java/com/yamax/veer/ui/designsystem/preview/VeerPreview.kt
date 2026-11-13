package com.yamax.veer.ui.designsystem.preview

import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import com.yamax.veer.ui.designsystem.theme.VeerDesignSystemTheme
import com.yamax.veer.ui.theme.ThemeMode

@Target(AnnotationTarget.FUNCTION, AnnotationTarget.ANNOTATION_CLASS)
@Retention(AnnotationRetention.BINARY)
@Preview(
    name = "Light",
    group = "Theme",
    widthDp = 360,
    heightDp = 800,
    uiMode = Configuration.UI_MODE_NIGHT_NO,
    showBackground = true,
)
@Preview(
    name = "Dark",
    group = "Theme",
    widthDp = 360,
    heightDp = 800,
    uiMode = Configuration.UI_MODE_NIGHT_YES,
    showBackground = true,
)
annotation class VeerThemePreviews

@Target(AnnotationTarget.FUNCTION, AnnotationTarget.ANNOTATION_CLASS)
@Retention(AnnotationRetention.BINARY)
@Preview(
    name = "Small width",
    group = "Responsive",
    widthDp = 320,
    heightDp = 640,
    showBackground = true,
)
@Preview(
    name = "Large font",
    group = "Responsive",
    widthDp = 360,
    heightDp = 800,
    fontScale = 1.5f,
    showBackground = true,
)
annotation class VeerResponsivePreviews

@Composable
fun VeerPreview(
    darkTheme: Boolean? = null,
    content: @Composable () -> Unit,
) {
    VeerDesignSystemTheme(
        themeMode = when (darkTheme) {
            true -> ThemeMode.DARK
            false -> ThemeMode.LIGHT
            null -> ThemeMode.SYSTEM
        },
        dynamicColor = false,
        content = content,
    )
}
