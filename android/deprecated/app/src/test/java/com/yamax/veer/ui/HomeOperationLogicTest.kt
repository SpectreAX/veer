package com.yamax.veer.ui

import com.yamax.veer.R
import com.yamax.veer.core_mihomo.EngineState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeOperationLogicTest {

    @Test
    fun noProfileAlwaysDirectsStoppedRuntimeToImport() {
        val action = homePrimaryAction(
            engineState = EngineState.Stopped,
            hasActiveProfile = false,
        )

        assertEquals(HomePrimaryAction.IMPORT_PROFILE, action.action)
        assertEquals(R.string.home_action_import_profile, action.labelRes)
        assertTrue(action.enabled)
    }

    @Test
    fun primaryActionTracksEveryRuntimeState() {
        assertEquals(
            HomePrimaryAction.START,
            homePrimaryAction(EngineState.Stopped, hasActiveProfile = true).action,
        )
        assertFalse(
            homePrimaryAction(EngineState.Starting, hasActiveProfile = true).enabled,
        )
        assertEquals(
            HomePrimaryAction.STOP,
            homePrimaryAction(EngineState.Running, hasActiveProfile = true).action,
        )
        assertFalse(
            homePrimaryAction(EngineState.Stopping, hasActiveProfile = true).enabled,
        )
        assertEquals(
            HomePrimaryAction.RECOVER_ERROR,
            homePrimaryAction(EngineState.Error("test"), hasActiveProfile = true).action,
        )
    }

    @Test
    fun aiAllowsLocalCommandsWithoutKeyOnceVpnIsRunning() {
        assertEquals(
            AiExecutionReadiness.NO_PROFILE,
            aiExecutionReadiness(EngineState.Stopped, false, false),
        )
        assertEquals(
            AiExecutionReadiness.VPN_NOT_RUNNING,
            aiExecutionReadiness(EngineState.Stopped, true, true),
        )
        assertEquals(
            AiExecutionReadiness.LOCAL_ONLY,
            aiExecutionReadiness(EngineState.Running, true, false),
        )
        assertTrue(
            aiExecutionReadiness(EngineState.Running, true, false).canExecute,
        )
        assertEquals(
            AiExecutionReadiness.READY,
            aiExecutionReadiness(EngineState.Running, true, true),
        )
        assertTrue(
            aiExecutionReadiness(EngineState.Running, true, true).canExecute,
        )
        assertFalse(
            aiExecutionReadiness(EngineState.Stopped, true, true).canExecute,
        )
    }
}
