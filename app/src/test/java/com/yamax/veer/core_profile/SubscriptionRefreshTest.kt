package com.yamax.veer.core_profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscriptionRefreshTest {
    @Test
    fun `diff reports additions removals and hash change`() {
        val before = metadata(proxies = 10, groups = 4, rules = 8, hash = "old")
        val after = metadata(proxies = 12, groups = 3, rules = 8, hash = "new")

        val diff = SubscriptionDiffSummary.between(before, after)

        assertEquals(2, diff.proxiesAdded)
        assertEquals(0, diff.proxiesRemoved)
        assertEquals(0, diff.groupsAdded)
        assertEquals(1, diff.groupsRemoved)
        assertEquals(0, diff.rulesAdded)
        assertEquals(0, diff.rulesRemoved)
        assertTrue(diff.configChanged)
    }

    @Test
    fun `unchanged metadata produces empty diff`() {
        val metadata = metadata(proxies = 10, groups = 4, rules = 8, hash = "same")

        val diff = SubscriptionDiffSummary.between(metadata, metadata)

        assertEquals(0, diff.proxiesAdded + diff.proxiesRemoved)
        assertEquals(0, diff.groupsAdded + diff.groupsRemoved)
        assertEquals(0, diff.rulesAdded + diff.rulesRemoved)
        assertFalse(diff.configChanged)
    }

    @Test
    fun `history error removes urls and query credentials`() {
        val sanitized = SubscriptionRefreshManager.sanitizeError(
            "fetch https://example.com/sub?token=secret failed; key=also-secret",
        )

        assertFalse(sanitized.contains("secret"))
        assertFalse(sanitized.contains("example.com"))
        assertTrue(sanitized.contains("[redacted-url]"))
    }

    private fun metadata(
        proxies: Int,
        groups: Int,
        rules: Int,
        hash: String,
    ) = ProfileMetadata(
        id = ProfileId("profile"),
        displayName = "Subscription",
        source = ProfileSource.SubscriptionUrl(
            url = "https://example.invalid/sub",
            lastFetchedMs = 1L,
        ),
        importedAtMs = 1L,
        lastUpdatedMs = 1L,
        proxyCount = proxies,
        groupCount = groups,
        ruleCount = rules,
        rawSizeBytes = 100L,
        configHashSha256 = hash,
    )
}
