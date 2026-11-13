package com.yamax.veer.core

sealed interface EngineState {
    data object Stopped : EngineState
    data object Starting : EngineState
    data object Running : EngineState
    data object Stopping : EngineState
    data class Error(val message: String) : EngineState
}
