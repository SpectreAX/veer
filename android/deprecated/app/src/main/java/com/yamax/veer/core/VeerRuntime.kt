package com.yamax.veer.core

import kotlinx.coroutines.flow.StateFlow

/**
 * Boundary for the future VpnService + gomobile runtime.
 *
 * The real implementation is intentionally not present until the lifecycle governance
 * documents listed in docs/IMPLEMENTATION_STATUS.md are restored to this repository.
 */
interface VeerRuntime {
    val state: StateFlow<EngineState>

    suspend fun start()

    suspend fun stop()
}
