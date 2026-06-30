package com.yamax.veer.core_profile.internal.parser

import android.util.Base64

internal object Base64Decoder {

    /**
     * Decodes a Base64-encoded string to a UTF-8 string.
     * Accepts both standard (RFC 4648) and URL-safe variants, with or without padding.
     */
    fun decode(encoded: String): Result<String> = runCatching {
        val trimmed = encoded.trim()
        // Try URL-safe + no-padding first, then standard
        val bytes = try {
            Base64.decode(trimmed, Base64.URL_SAFE or Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            Base64.decode(trimmed, Base64.DEFAULT or Base64.NO_WRAP)
        }
        String(bytes, Charsets.UTF_8)
    }
}
