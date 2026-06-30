package com.yamax.veer.data

import android.content.Context
import androidx.core.content.edit
import com.yamax.veer.BuildConfig

/**
 * Tiny SharedPreferences wrapper for runtime-supplied secrets.
 *
 * Resolution order: user-entered value → BuildConfig (set via local.properties)
 * → empty string. The LLM client treats empty as a clear "API key missing"
 * error at first call.
 *
 * SharedPreferences is plaintext on the device — fine for a personal dev key,
 * not fine for production-grade secrets. Swap to EncryptedSharedPreferences
 * once the app ships outside the dev box.
 */
object ApiKeyStore {

    private const val PREFS = "veer_secrets"
    private const val KEY_DEEPSEEK = "deepseek_api_key"

    fun deepseekKey(context: Context): String {
        val stored = prefs(context).getString(KEY_DEEPSEEK, null).orEmpty().trim()
        return stored.ifEmpty { BuildConfig.DEEPSEEK_API_KEY }
    }

    fun setDeepseekKey(context: Context, key: String) {
        prefs(context).edit { putString(KEY_DEEPSEEK, key.trim()) }
    }

    fun clearDeepseekKey(context: Context) {
        prefs(context).edit { remove(KEY_DEEPSEEK) }
    }

    /** True if the user has explicitly stored a key (BuildConfig fallback ignored). */
    fun hasUserKey(context: Context): Boolean =
        prefs(context).getString(KEY_DEEPSEEK, null).orEmpty().isNotBlank()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
