package com.yamax.veer.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionStatusRepositoryTest {

    @Test
    fun `speed history starts empty and retains only latest sixty samples`() {
        val buffer = SpeedHistoryBuffer()

        assertTrue(buffer.snapshot().isEmpty())
        repeat(65) { index ->
            buffer.append(
                SpeedSample(
                    timestamp = index * 1_000L,
                    uploadSpeed = index.toLong(),
                    downloadSpeed = index.toLong(),
                ),
            )
        }

        val result = buffer.snapshot()
        assertEquals(60, result.size)
        assertEquals(5_000L, result.first().timestamp)
        assertEquals(64_000L, result.last().timestamp)
    }

    @Test
    fun `speed history prunes samples outside sixty second window`() {
        val buffer = SpeedHistoryBuffer()
        buffer.append(SpeedSample(timestamp = 1_000L, uploadSpeed = 1, downloadSpeed = 2))
        buffer.append(SpeedSample(timestamp = 30_000L, uploadSpeed = 3, downloadSpeed = 4))

        val result = buffer.prune(nowMs = 61_001L)

        assertEquals(listOf(30_000L), result.map { it.timestamp })
    }

    @Test
    fun `speed history sanitizes negative values and clears completely`() {
        val buffer = SpeedHistoryBuffer()

        val appended = buffer.append(
            SpeedSample(timestamp = 1_000L, uploadSpeed = -10, downloadSpeed = -20),
        )

        assertEquals(0L, appended.single().uploadSpeed)
        assertEquals(0L, appended.single().downloadSpeed)
        assertTrue(buffer.clear().isEmpty())
        assertTrue(buffer.snapshot().isEmpty())
    }

    @Test
    fun `speed calculation records pure download traffic`() {
        val result = calculateSpeedSample(
            previousUploadTotal = 0,
            previousDownloadTotal = 0,
            currentUploadTotal = 0,
            currentDownloadTotal = 2_048,
            previousTimestampMs = 1_000,
            currentTimestampMs = 2_000,
        )

        assertEquals(0L, result?.uploadSpeed)
        assertEquals(2_048L, result?.downloadSpeed)
    }

    @Test
    fun `speed calculation rejects stale intervals and reset counters`() {
        assertNull(
            calculateSpeedSample(
                previousUploadTotal = 10,
                previousDownloadTotal = 20,
                currentUploadTotal = 20,
                currentDownloadTotal = 40,
                previousTimestampMs = 1_000,
                currentTimestampMs = 7_000,
            ),
        )
        assertNull(
            calculateSpeedSample(
                previousUploadTotal = 10,
                previousDownloadTotal = 20,
                currentUploadTotal = 0,
                currentDownloadTotal = 0,
                previousTimestampMs = 1_000,
                currentTimestampMs = 2_000,
            ),
        )
    }

    @Test
    fun `exit identity accepts nested API responses`() {
        val result = ConnectionStatusRepository.parseExitIdentity(
            ipv4Body = """{"data":{"ip":"203.0.113.8"}}""",
            ipv6Body = """{"address":"2001:db8::8"}""",
            geoBody = """
                {
                  "data": {
                    "country_code": "JP",
                    "country": "Japan",
                    "region": "Tokyo",
                    "city": "Chiyoda"
                  }
                }
            """.trimIndent(),
        )

        assertEquals("203.0.113.8", result.ipv4)
        assertEquals("2001:db8::8", result.ipv6)
        assertEquals("JP", result.countryCode)
        assertEquals("JP · Tokyo · Chiyoda", result.locationLabel)
    }

    @Test
    fun `exit identity extracts plain response and ignores invalid address`() {
        val result = ConnectionStatusRepository.parseExitIdentity(
            ipv4Body = "Current address: 198.51.100.7",
            ipv6Body = "IPv6 unavailable",
            geoBody = """{"country_name":"Singapore"}""",
        )

        assertEquals("198.51.100.7", result.ipv4)
        assertNull(result.ipv6)
        assertEquals("Singapore", result.locationLabel)
    }

    @Test
    fun `exit identity reads Cloudflare trace location`() {
        val result = ConnectionStatusRepository.parseExitIdentity(
            ipv4Body = """{"ip":"203.0.113.9"}""",
            ipv6Body = null,
            geoBody = """
                fl=29f
                h=www.cloudflare.com
                ip=203.0.113.9
                loc=HK
                tls=TLSv1.3
            """.trimIndent(),
        )

        assertEquals("HK", result.countryCode)
        assertEquals("HK", result.locationLabel)
    }

    @Test
    fun `exit identity cache is reused for the same route before expiry`() {
        assertTrue(
            ConnectionStatusRepository.shouldReuseExitIdentity(
                nowMs = 59_999,
                cachedAtMs = 0,
                routeKey = "PROXY\u0000Hong Kong 01",
                cachedRouteKey = "PROXY\u0000Hong Kong 01",
                cached = ExitIdentity(ipv4 = "203.0.113.10"),
            ),
        )
    }

    @Test
    fun `exit identity cache is invalidated when the selected node changes`() {
        assertFalse(
            ConnectionStatusRepository.shouldReuseExitIdentity(
                nowMs = 5_000,
                cachedAtMs = 0,
                routeKey = "PROXY\u0000Japan 01",
                cachedRouteKey = "PROXY\u0000Hong Kong 01",
                cached = ExitIdentity(ipv4 = "203.0.113.10"),
            ),
        )
    }

    @Test
    fun `exit identity cache expires after one minute`() {
        assertFalse(
            ConnectionStatusRepository.shouldReuseExitIdentity(
                nowMs = ConnectionStatusRepository.EXIT_CACHE_MS,
                cachedAtMs = 0,
                routeKey = "PROXY\u0000Hong Kong 01",
                cachedRouteKey = "PROXY\u0000Hong Kong 01",
                cached = ExitIdentity(ipv4 = "203.0.113.10"),
            ),
        )
    }
}
