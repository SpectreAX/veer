package com.yamax.veer.core_mihomo.ipc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreProcessRecoveryPolicyTest {
    @Test
    fun `recovers when the previously running core pid is replaced`() {
        assertTrue(
            CoreProcessRecoveryPolicy.shouldRecover(
                previousProcessId = 10,
                currentProcessId = 11,
                lastRunningProcessId = 10,
                currentCoreStopped = true,
                desiredRunning = true,
            ),
        )
    }

    @Test
    fun `does not recover an explicit stop`() {
        assertFalse(
            CoreProcessRecoveryPolicy.shouldRecover(
                previousProcessId = 10,
                currentProcessId = 11,
                lastRunningProcessId = 10,
                currentCoreStopped = true,
                desiredRunning = false,
            ),
        )
    }

    @Test
    fun `does not recover ordinary state changes in the same process`() {
        assertFalse(
            CoreProcessRecoveryPolicy.shouldRecover(
                previousProcessId = 10,
                currentProcessId = 10,
                lastRunningProcessId = 10,
                currentCoreStopped = true,
                desiredRunning = true,
            ),
        )
    }

    @Test
    fun `does not recover a process that was never observed running`() {
        assertFalse(
            CoreProcessRecoveryPolicy.shouldRecover(
                previousProcessId = 10,
                currentProcessId = 11,
                lastRunningProcessId = 0,
                currentCoreStopped = true,
                desiredRunning = true,
            ),
        )
    }
}
