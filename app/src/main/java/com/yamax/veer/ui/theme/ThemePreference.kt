package com.yamax.veer.ui.theme

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class ThemeMode {
    SYSTEM,
    LIGHT,
    DARK,
}

/** Persists the user-selected appearance and exposes it to every activity. */
internal object ThemePreference {
    private const val PREFERENCES_NAME = "veer_appearance"
    private const val KEY_THEME_MODE = "theme_mode"

    private val mutableMode = MutableStateFlow(ThemeMode.SYSTEM)
    val mode: StateFlow<ThemeMode> = mutableMode.asStateFlow()

    fun initialize(context: Context) {
        mutableMode.value = read(context)
    }

    fun read(context: Context): ThemeMode {
        val stored = preferences(context).getString(KEY_THEME_MODE, null)
        return stored
            ?.let { value -> ThemeMode.entries.firstOrNull { it.name == value } }
            ?: ThemeMode.SYSTEM
    }

    fun set(context: Context, mode: ThemeMode) {
        preferences(context).edit { putString(KEY_THEME_MODE, mode.name) }
        mutableMode.value = mode
    }

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(
            PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
}

internal fun resolveDarkTheme(mode: ThemeMode, systemDark: Boolean): Boolean = when (mode) {
    ThemeMode.SYSTEM -> systemDark
    ThemeMode.LIGHT -> false
    ThemeMode.DARK -> true
}
