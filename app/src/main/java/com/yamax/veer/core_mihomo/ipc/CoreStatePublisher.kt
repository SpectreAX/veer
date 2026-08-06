package com.yamax.veer.core_mihomo.ipc

import android.content.Context
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.MihomoEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

internal object CoreStatePublisher {
    private val initialized = AtomicBoolean()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun init(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        val resolver = context.applicationContext.contentResolver
        scope.launch {
            combine(
                MihomoEngine.status,
                MihomoEngine.startupStage,
                AppStateRepository.appState,
            ) { status, startup, appState ->
                PublisherKey(
                    engineKind = CoreStateProtocol.engineKind(status.state),
                    engineError = (status.state as? com.yamax.veer.core_mihomo.EngineState.Error)?.message,
                    operationId = status.operationId,
                    timestampMs = status.timestampMs,
                    machineCode = status.machineCode,
                    startupStage = startup.name,
                    physicalNetworks = appState.connectivity.physicalNetworksAvailable,
                    hasInternet = appState.connectivity.hasInternet,
                )
            }
                .distinctUntilChanged()
                .collect {
                    resolver.notifyChange(CoreStateProtocol.URI, null)
                }
        }
    }

    private data class PublisherKey(
        val engineKind: String,
        val engineError: String?,
        val operationId: String,
        val timestampMs: Long,
        val machineCode: String,
        val startupStage: String,
        val physicalNetworks: Int,
        val hasInternet: Boolean,
    )
}
