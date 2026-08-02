package com.yamax.veer.core_profile

import kotlinx.serialization.Serializable

@Serializable
internal data class ProfileMetadata(
    val id: ProfileId,
    val displayName: String,
    val source: ProfileSource,
    val importedAtMs: Long,
    val lastUpdatedMs: Long,
    val proxyCount: Int,
    val groupCount: Int,
    val ruleCount: Int,
    val rawSizeBytes: Long,
    /** SHA-256 hex of the generated Mihomo runtime config produced at import. */
    val configHashSha256: String,
    /** Provider quota/expiry response metadata; null when the provider omits it. */
    val subscriptionUsage: SubscriptionUsage? = null,
)
