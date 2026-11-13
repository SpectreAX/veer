package com.yamax.veer.core_mihomo

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Emits only when the physical-network set remains empty for the full grace period. */
internal class SustainedNetworkLossDebouncer(
    private val scope: CoroutineScope,
    private val debounceMs: Long,
    private val isStillLost: () -> Boolean,
    private val onSustainedLoss: () -> Unit,
) {
    private val lock = Any()
    private var pending: Job? = null

    init {
        require(debounceMs >= 0L) { "debounceMs must not be negative" }
    }

    fun onAllNetworksAbsent() {
        synchronized(lock) {
            pending?.cancel()
            pending = scope.launch {
                delay(debounceMs)
                val emit = synchronized(lock) {
                    pending = null
                    isStillLost()
                }
                if (emit) onSustainedLoss()
            }
        }
    }

    fun onNetworkAvailable() {
        synchronized(lock) {
            pending?.cancel()
            pending = null
        }
    }

    fun cancel() = onNetworkAvailable()
}
