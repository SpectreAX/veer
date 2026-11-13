package com.yamax.veer.core_mihomo

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

internal enum class CoreRuntimeMutation {
    ROUTE_SELECTION_CHANGED,
    RULES_RELOADED,
}

/**
 * Process-local invalidation bus for successful runtime mutations initiated by
 * the Android UI/AI layer. It lets the dashboard refresh immediately without
 * turning steady-state diagnostics into aggressive polling.
 */
internal object CoreRuntimeEvents {
    private val _mutations = MutableSharedFlow<CoreRuntimeMutation>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val mutations: SharedFlow<CoreRuntimeMutation> = _mutations.asSharedFlow()

    fun publish(mutation: CoreRuntimeMutation) {
        _mutations.tryEmit(mutation)
    }
}
