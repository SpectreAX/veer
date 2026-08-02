package com.yamax.veer.core_mihomo.ipc

import android.content.Context
import android.database.ContentObserver
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.CoreRunStateStore
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.VeerVpnService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Main-process proxy for the lifecycle and lightweight counters in `:veercore`. */
internal object CoreStateClient {
    private val initialized = AtomicBoolean()
    private val refreshQueued = AtomicBoolean()
    private val refreshRequested = AtomicBoolean()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var appContext: Context? = null
    @Volatile private var lastCoreProcessId: Int = 0
    @Volatile private var lastRunningProcessId: Int = 0
    @Volatile private var lastRecoveryProcessId: Int = 0

    fun init(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        appContext = context.applicationContext
        context.contentResolver.registerContentObserver(
            CoreStateProtocol.URI,
            false,
            object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    requestRefresh()
                }
            },
        )
        requestRefresh()
    }

    fun isAvailable(): Boolean = initialized.get()

    fun trafficSnapshot(): CoreTrafficSnapshot? {
        val bundle = call(CoreStateProtocol.METHOD_TRAFFIC) ?: return null
        return CoreTrafficSnapshot(
            uploadTotal = bundle.getLong(CoreStateProtocol.KEY_UPLOAD_TOTAL),
            downloadTotal = bundle.getLong(CoreStateProtocol.KEY_DOWNLOAD_TOTAL),
            activeConnections = bundle.getInt(CoreStateProtocol.KEY_ACTIVE_CONNECTIONS),
        )
    }

    fun dashboardRoutingSnapshot(defaultPolicy: String?): CoreDashboardRoutingSnapshot? {
        val extras = Bundle().apply {
            putString(CoreStateProtocol.KEY_DEFAULT_POLICY, defaultPolicy.orEmpty())
        }
        val bundle = call(CoreStateProtocol.METHOD_DASHBOARD, extras) ?: return null
        return CoreDashboardRoutingSnapshot(
            coreRunning = bundle.getBoolean(CoreStateProtocol.KEY_CORE_RUNNING),
            mode = bundle.getString(CoreStateProtocol.KEY_MODE).orEmpty(),
            policy = bundle.getString(CoreStateProtocol.KEY_POLICY)?.takeIf(String::isNotBlank),
            selectedNode = bundle.getString(CoreStateProtocol.KEY_SELECTED_NODE)
                ?.takeIf(String::isNotBlank),
            nodeDelayMs = bundle.getInt(
                CoreStateProtocol.KEY_NODE_DELAY_MS,
                CoreStateProtocol.UNKNOWN_DELAY_MS,
            ).takeIf { it >= 0 },
        )
    }

    fun logSnapshot(limit: Int = 200): List<String> {
        val extras = Bundle().apply {
            putInt(CoreStateProtocol.KEY_LOG_LIMIT, limit)
        }
        return call(CoreStateProtocol.METHOD_LOGS, extras)
            ?.getStringArrayList(CoreStateProtocol.KEY_LOG_LINES)
            .orEmpty()
    }

    fun reloadRules(configFile: File): CoreReloadResult? {
        val directory = configFile.parentFile ?: return null
        val extras = Bundle().apply {
            putString(CoreStateProtocol.KEY_CONFIG_DIRECTORY, directory.absolutePath)
            putString(CoreStateProtocol.KEY_CONFIG_FILE, configFile.name)
        }
        val result = call(CoreStateProtocol.METHOD_RELOAD_RULES, extras) ?: return null
        return CoreReloadResult(
            success = result.getBoolean(CoreStateProtocol.KEY_SUCCESS),
            status = result.getInt(CoreStateProtocol.KEY_STATUS, -1),
            message = result.getString(CoreStateProtocol.KEY_MESSAGE).orEmpty(),
        )
    }

    private fun requestRefresh() {
        refreshRequested.set(true)
        if (!refreshQueued.compareAndSet(false, true)) return
        scope.launch {
            try {
                while (refreshRequested.getAndSet(false)) {
                    refreshRuntimeSnapshot()
                }
            } finally {
                refreshQueued.set(false)
                // Close the race where a notification arrived after the loop
                // observed false but before refreshQueued was released.
                if (refreshRequested.get()) {
                    requestRefresh()
                }
            }
        }
    }

    private fun refreshRuntimeSnapshot() {
        val bundle = call(CoreStateProtocol.METHOD_RUNTIME) ?: return
        val processId = bundle.getInt(CoreStateProtocol.KEY_PROCESS_ID)
        val previousProcessId = lastCoreProcessId
        val engineState = CoreStateProtocol.decodeEngineState(
            bundle.getString(CoreStateProtocol.KEY_ENGINE_KIND),
            bundle.getString(CoreStateProtocol.KEY_ENGINE_ERROR),
        )
        val startupStage = CoreStateProtocol.decodeStartupStage(
            bundle.getString(CoreStateProtocol.KEY_STARTUP_STAGE),
        )
        if (MihomoEngine.state.value != engineState) {
            MihomoEngine.setState(engineState)
        }
        if (MihomoEngine.startupStage.value != startupStage) {
            MihomoEngine.setStartupStage(startupStage)
        }
        AppStateRepository.updateConnectivity(
            physicalNetworksAvailable =
                bundle.getInt(CoreStateProtocol.KEY_PHYSICAL_NETWORKS),
            hasInternet = bundle.getBoolean(CoreStateProtocol.KEY_HAS_INTERNET),
        )
        if (engineState is EngineState.Running) {
            lastRunningProcessId = processId
        }
        lastCoreProcessId = processId
        recoverCoreAfterUnexpectedProcessDeath(
            previousProcessId = previousProcessId,
            currentProcessId = processId,
            engineState = engineState,
        )
        VeerLog.core(
            "[CoreStateClient] synced pid=$processId" +
                " state=$engineState stage=$startupStage",
        )
    }

    private fun recoverCoreAfterUnexpectedProcessDeath(
        previousProcessId: Int,
        currentProcessId: Int,
        engineState: EngineState,
    ) {
        val context = appContext ?: return
        if (!CoreProcessRecoveryPolicy.shouldRecover(
                previousProcessId = previousProcessId,
                currentProcessId = currentProcessId,
                lastRunningProcessId = lastRunningProcessId,
                currentCoreStopped = engineState is EngineState.Stopped,
                desiredRunning = CoreRunStateStore.isDesiredRunning(context),
            )
        ) {
            return
        }
        if (lastRecoveryProcessId == currentProcessId) return
        lastRecoveryProcessId = currentProcessId

        if (VpnService.prepare(context) != null) {
            CoreRunStateStore.setDesiredRunning(context, false)
            VeerLog.core(
                "[CoreStateClient] core recovery cancelled: VPN permission is unavailable",
                VeerLog.Level.WARN,
            )
            return
        }
        runCatching {
            ContextCompat.startForegroundService(
                context,
                VeerVpnService.startIntent(context),
            )
        }.onSuccess {
            VeerLog.core(
                "[CoreStateClient] restarted core after pid $previousProcessId died; " +
                    "replacement pid=$currentProcessId",
                VeerLog.Level.WARN,
            )
        }.onFailure {
            VeerLog.core(
                "[CoreStateClient] failed to restart core after process death: ${it.message}",
                VeerLog.Level.ERROR,
            )
        }
    }

    private fun call(method: String, extras: Bundle? = null): Bundle? {
        val resolver = appContext?.contentResolver ?: return null
        return runCatching {
            resolver.call(CoreStateProtocol.URI, method, null, extras)
        }.onFailure {
            VeerLog.core(
                "[CoreStateClient] $method failed: ${it.message}",
                VeerLog.Level.WARN,
            )
        }.getOrNull()
    }
}
