package com.yamax.veer.core_profile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscriptionMetadataTest {

    @Test
    fun `English quota and expiry rows are metadata`() {
        assertTrue(SubscriptionMetadata.isLikelyMetadataName("Traffic: 56.9 GB / 200 GB"))
        assertTrue(SubscriptionMetadata.isLikelyMetadataName("Expire: 2026-09-04"))
        assertFalse(SubscriptionMetadata.isLikelyMetadataName("US Traffic Optimized 01"))
    }
}
