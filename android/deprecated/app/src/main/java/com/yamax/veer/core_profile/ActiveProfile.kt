package com.yamax.veer.core_profile

import kotlinx.serialization.Serializable

@Serializable
internal data class ActiveProfile(
    val profileId: ProfileId,
    val activatedAtMs: Long,
    /** SHA-256 hex of the generated Mihomo runtime config installed at activation. */
    val generatedConfigHash: String,
)
