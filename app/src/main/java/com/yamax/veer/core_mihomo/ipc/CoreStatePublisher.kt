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
                MihomoEngine.state,
                MihomoEngine.startupStage,
                AppStateRepository.appState,
            ) { engine, startup, appState ->
                PublisherKey(
                    engineKind = CoreStateProtocol.engineKind(engine),
                    engineError = (engine as? com.yamax.veer.core_mihomo.EngineState.Error)?.message,
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
        val startupStage: String,
        val physicalNetworks: Int,
        val hasInternet: Boolean,
    )
}
