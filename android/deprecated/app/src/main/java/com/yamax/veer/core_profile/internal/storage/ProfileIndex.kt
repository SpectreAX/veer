package com.yamax.veer.core_profile.internal.storage

import com.yamax.veer.core_profile.ActiveProfile
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.core_profile.ProfileMetadata
import kotlinx.serialization.Serializable

@Serializable
internal data class ProfileIndex(
    val profiles: List<ProfileMetadata> = emptyList(),
    val active: ActiveProfile? = null,
    val lastKnownGood: ActiveProfile? = null,
    val lastActivationFailure: ProfileActivationFailure? = null,
    /** Custom DNS policy keyed by ProfileId.value. INHERIT entries are omitted. */
    val dnsOverrides: Map<String, DnsOverridePolicy> = emptyMap(),
)
