package com.yamax.veer.core_mihomo

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeReadinessVerifierTest {

    @Test
    fun `requires native runtime and controller in the same attempt`() = runTest {
        val evidence = ArrayDeque(
            listOf(
                RuntimeReadinessEvidence(true, false),
                RuntimeReadinessEvidence(false, true),
                RuntimeReadinessEvidence(true, true),
            ),
        )
        var pauses = 0
        val result = RuntimeReadinessVerifier(
            maxAttempts = 5,
            retryDelayMs = 100,
            probe = { evidence.removeFirst() },
            pause = { pauses++ },
        ).await()

        assertTrue(result is RuntimeReadinessResult.Ready)
        assertEquals(3, (result as RuntimeReadinessResult.Ready).attempts)
        assertEquals(2, pauses)
    }

    @Test
    fun `times out with the final evidence`() = runTest {
        val last = RuntimeReadinessEvidence(true, false)
        val result = RuntimeReadinessVerifier(
            maxAttempts = 3,
            retryDelayMs = 0,
            probe = { last },
            pause = {},
        ).await()

        assertEquals(RuntimeReadinessResult.TimedOut(3, last), result)
    }

    @Test
    fun `cancellation prevents another probe`() = runTest {
        var probes = 0
        var cancelled = false
        val result = RuntimeReadinessVerifier(
            maxAttempts = 5,
            retryDelayMs = 0,
            probe = {
                probes++
                cancelled = true
                RuntimeReadinessEvidence(false, false)
            },
            isCancelled = { cancelled },
            pause = {},
        ).await()

        assertEquals(1, probes)
        assertEquals(
            RuntimeReadinessResult.Cancelled(1, RuntimeReadinessEvidence(false, false)),
            result,
        )
    }
}
