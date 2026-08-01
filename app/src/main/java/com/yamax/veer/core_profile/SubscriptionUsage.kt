package com.yamax.veer.core_profile

import kotlinx.serialization.Serializable

@Serializable
internal data class SubscriptionUsage(
    val uploadBytes: Long = 0,
    val downloadBytes: Long = 0,
    val totalBytes: Long = 0,
    val expireAtMs: Long? = null,
    val fetchedAtMs: Long,
) {
    val usedBytes: Long get() = (uploadBytes + downloadBytes).coerceAtLeast(0)
    val remainingBytes: Long get() = (totalBytes - usedBytes).coerceAtLeast(0)
}

internal object SubscriptionUsageParser {
    fun parse(
        header: String?,
        fetchedAtMs: Long = System.currentTimeMillis(),
    ): SubscriptionUsage? {
        if (header.isNullOrBlank()) return null
        val values = header.split(';')
            .mapNotNull { part ->
                val key = part.substringBefore('=', "").trim().lowercase()
                val value = part.substringAfter('=', "").trim().toLongOrNull()
                if (key.isBlank() || value == null || value < 0) null else key to value
            }
            .toMap()
        if (values.keys.none { it in KNOWN_KEYS }) return null
        val expireSeconds = values["expire"]?.takeIf { it > 0 }
        return SubscriptionUsage(
            uploadBytes = values["upload"] ?: 0,
            downloadBytes = values["download"] ?: 0,
            totalBytes = values["total"] ?: 0,
            expireAtMs = expireSeconds?.let {
                if (it <= Long.MAX_VALUE / 1_000) it * 1_000 else null
            },
            fetchedAtMs = fetchedAtMs,
        )
    }

    private val KNOWN_KEYS = setOf("upload", "download", "total", "expire")
}
