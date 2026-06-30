package com.yamax.veer.core_profile

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
@JvmInline
internal value class ProfileId(val value: String) {
    companion object {
        fun generate(): ProfileId = ProfileId(UUID.randomUUID().toString())
    }
    override fun toString(): String = value
}
