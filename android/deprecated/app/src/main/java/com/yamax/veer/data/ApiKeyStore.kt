package com.yamax.veer.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.edit
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Tiny SharedPreferences wrapper for runtime-supplied secrets.
 *
 * The ciphertext and IV live in SharedPreferences; the non-exportable AES key
 * lives in Android Keystore. A legacy plaintext preference is migrated on the
 * first read after upgrade and immediately removed.
 */
object ApiKeyStore {

    private const val PREFS = "veer_secrets"
    private const val KEY_DEEPSEEK = "deepseek_api_key"
    private const val KEY_DEEPSEEK_ENCRYPTED = "deepseek_api_key_encrypted"
    private const val KEY_ALIAS = "veer_deepseek_api_key"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"

    fun deepseekKey(context: Context): String {
        val preferences = prefs(context)
        val encrypted = preferences.getString(KEY_DEEPSEEK_ENCRYPTED, null)
        if (!encrypted.isNullOrBlank()) {
            return runCatching { decrypt(encrypted) }.getOrDefault("")
        }
        val legacy = preferences.getString(KEY_DEEPSEEK, null).orEmpty().trim()
        if (legacy.isNotEmpty()) {
            setDeepseekKey(context, legacy)
            return legacy
        }
        return ""
    }

    fun setDeepseekKey(context: Context, key: String) {
        val value = key.trim()
        require(value.isNotEmpty()) { "API key must not be empty" }
        val encrypted = encrypt(value)
        // Secret updates are rare and must survive an immediate process stop
        // (for example, Android reclaiming the settings process right after
        // the user taps Save). SharedPreferences.apply() can lose that update
        // before its asynchronous disk write runs, so commit synchronously.
        prefs(context).edit(commit = true) {
            putString(KEY_DEEPSEEK_ENCRYPTED, encrypted)
            remove(KEY_DEEPSEEK)
        }
    }

    fun clearDeepseekKey(context: Context) {
        prefs(context).edit(commit = true) {
            remove(KEY_DEEPSEEK)
            remove(KEY_DEEPSEEK_ENCRYPTED)
        }
    }

    fun hasUserKey(context: Context): Boolean =
        deepseekKey(context).isNotBlank()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val parts = encoded.split(':', limit = 2)
        require(parts.size == 2) { "Invalid encrypted API key" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateKey(),
            GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)),
        )
        return String(
            cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)),
            Charsets.UTF_8,
        )
    }

    private fun getOrCreateKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build(),
                )
            }
            .generateKey()
    }

    private const val TRANSFORMATION = "AES/GCM/NoPadding"
}
