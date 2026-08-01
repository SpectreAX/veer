package com.yamax.veer.core_profile.internal.storage

import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileIndexDnsMigrationTest {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Test
    fun `legacy index without dns overrides migrates to empty map`() {
        val decoded = json.decodeFromString<ProfileIndex>(
            """{"profiles":[],"active":null,"lastKnownGood":null,"lastActivationFailure":null}""",
        )

        assertTrue(decoded.dnsOverrides.isEmpty())
    }

    @Test
    fun `different profiles keep independent dns policies`() {
        val index = ProfileIndex(
            dnsOverrides = mapOf(
                "profile-a" to DnsOverridePolicy(
                    mode = DnsOverrideMode.CUSTOM,
                    defaultNameservers = listOf("1.1.1.1"),
                    nameservers = listOf("https://one.example/dns-query"),
                ),
                "profile-b" to DnsOverridePolicy(
                    mode = DnsOverrideMode.CUSTOM,
                    defaultNameservers = listOf("8.8.8.8"),
                    nameservers = listOf("tls://two.example:853"),
                ),
            ),
        )

        val decoded = json.decodeFromString<ProfileIndex>(json.encodeToString(index))

        assertEquals(
            listOf("https://one.example/dns-query"),
            decoded.dnsOverrides.getValue("profile-a").nameservers,
        )
        assertEquals(
            listOf("tls://two.example:853"),
            decoded.dnsOverrides.getValue("profile-b").nameservers,
        )
    }
}
