package com.yamax.veer.core_profile.internal.storage

import com.yamax.veer.core_profile.ProfileId
import kotlinx.serialization.Serializable

/**
 * Persistent, credential-free summary of the most recent profile startup
 * failure. Configuration contents and subscription sources are never stored.
 */
@Serializable
internal data class ProfileActivationFailure(
    val attemptedProfileId: ProfileId,
    val previousProfileId: ProfileId? = null,
    val stage: String,
    val message: String,
    val occurredAtMs: Long,
    val rollbackSucceeded: Boolean,
)
