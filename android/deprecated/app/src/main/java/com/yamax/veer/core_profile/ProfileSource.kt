package com.yamax.veer.core_profile

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
internal sealed class ProfileSource {

    @Serializable @SerialName("file")
    data class ClashFile(
        val originalFileName: String,
        val fileSizeBytes: Long,
    ) : ProfileSource()

    @Serializable @SerialName("url")
    data class SubscriptionUrl(
        val url: String,
        val lastFetchedMs: Long,
    ) : ProfileSource()

    @Serializable @SerialName("base64")
    data class Base64Text(
        val charCount: Int,
    ) : ProfileSource()
}
