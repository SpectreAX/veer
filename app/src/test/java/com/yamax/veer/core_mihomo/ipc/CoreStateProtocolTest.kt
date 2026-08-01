package com.yamax.veer.core_mihomo.ipc

import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.StartupStage
import org.junit.Assert.assertEquals
import org.junit.Test

class CoreStateProtocolTest {
    @Test
    fun `engine states survive protocol encoding`() {
        val states = listOf(
            EngineState.Stopped,
            EngineState.Starting,
            EngineState.Running,
            EngineState.Stopping,
            EngineState.Error("broken"),
        )

        states.forEach { state ->
            val decoded = CoreStateProtocol.decodeEngineState(
                CoreStateProtocol.engineKind(state),
                (state as? EngineState.Error)?.message,
            )
            assertEquals(state, decoded)
        }
    }

    @Test
    fun `unknown engine value fails closed to stopped`() {
        assertEquals(
            EngineState.Stopped,
            CoreStateProtocol.decodeEngineState("future-value", null),
        )
    }

    @Test
    fun `startup stages survive protocol encoding`() {
        StartupStage.entries.forEach { stage ->
            assertEquals(stage, CoreStateProtocol.decodeStartupStage(stage.name))
        }
    }

    @Test
    fun `unknown startup stage fails closed to idle`() {
        assertEquals(StartupStage.IDLE, CoreStateProtocol.decodeStartupStage("FUTURE_STAGE"))
    }
}
