package com.yamax.veer.core_profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SubscriptionUsageParserTest {
    @Test
    fun `parses standard subscription userinfo header`() {
        val usage = SubscriptionUsageParser.parse(
            "upload=1024; download=2048; total=10240; expire=2000000000",
            fetchedAtMs = 123,
        )!!

        assertEquals(1024, usage.uploadBytes)
        assertEquals(2048, usage.downloadBytes)
        assertEquals(3072, usage.usedBytes)
        assertEquals(7168, usage.remainingBytes)
        assertEquals(2_000_000_000_000, usage.expireAtMs)
        assertEquals(123, usage.fetchedAtMs)
    }

    @Test
    fun `ignores malformed and negative fields`() {
        val usage = SubscriptionUsageParser.parse(
            "upload=-1; download=oops; total=4096; expire=0",
        )!!

        assertEquals(0, usage.uploadBytes)
        assertEquals(0, usage.downloadBytes)
        assertEquals(4096, usage.remainingBytes)
        assertNull(usage.expireAtMs)
    }

    @Test
    fun `returns null for unrelated or absent header`() {
        assertNull(SubscriptionUsageParser.parse(null))
        assertNull(SubscriptionUsageParser.parse("foo=1; bar=2"))
    }
}
