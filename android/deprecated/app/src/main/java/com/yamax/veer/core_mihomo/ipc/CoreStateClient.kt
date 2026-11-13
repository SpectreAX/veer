package com.yamax.veer.core_mihomo.ipc

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.database.ContentObserver
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.CoreRunStateStore
import com.yamax.veer.core_mihomo.EngineRecoverability
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.VeerVpnService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Main-process proxy for the lifecycle and lightweight counters in `:veercore`. */
internal object CoreStateClient {
    private val initialized = AtomicBoolean()
    private val refreshQueued = AtomicBoolean()
    private val refreshRequested = AtomicBoolean()
    private val controlBinding = AtomicBoolean()
    private val controlBound = AtomicBoolean()
    private val binderDeathHandling = AtomicBoolean()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var appContext: Context? = null
    @Volatile private var lastCoreProcessId: Int = 0
    @Volatile private var lastRunningProcessId: Int = 0
    @Volatile private var lastRecoveryProcessId: Int = 0
    @Volatile private var control: IVeercoreControl? = null

    private val deathRecipient = IBinder.DeathRecipient {
        control = null
        handleBinderDeath("binderDied")
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            controlBinding.set(false)
            binderDeathHandling.set(false)
            control = IVeercoreControl.Stub.asInterface(service)
            runCatching { service?.linkToDeath(deathRecipient, 0) }
                .onFailure {
                    control = null
                    handleBinderDeath("linkToDeath failed: ${it.message}")
                    return
                }
            VeerLog.core("[CoreStateClient] AIDL connected")
            requestRefresh()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            control = null
            controlBinding.set(false)
            handleBinderDeath("service disconnected")
        }

        override fun onBindingDied(name: ComponentName?) {
            control = null
            controlBinding.set(false)
            unbindControl()
            handleBinderDeath("binding died")
        }

        override fun onNullBinding(name: ComponentName?) {
            control = null
            controlBinding.set(false)
            unbindControl()
            handleBinderDeath("null binding")
        }
    }

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
        // A stopped app has no remote state to discover. Eagerly binding here
        // cold-started :veercore for every UI/test process, kept it resident,
        // and made the UI depend on Android's remote-provider publication
        // deadline. A relaunched UI still reconnects immediately when the
        // durable desired-running marker says a VPN session should exist.
        if (CoreRunStateStore.isDesiredRunning(context.applicationContext)) {
            bindControl()
            requestRefresh()
        }
        // ContentProvider observers do not provide a Binder death callback when
        // their hosting process is killed. While the user still desires a
        // running VPN, periodically issue the lightweight runtime call. That
        // call re-creates the provider process, exposes its new PID and lets the
        // recovery policy convert the old Running generation into a serialized
        // replacement start instead of leaving stale UI state indefinitely.
        scope.launch {
            while (isActive) {
                delay(CORE_PROCESS_LIVENESS_INTERVAL_MS)
                if (CoreRunStateStore.isDesiredRunning(context.applicationContext)) {
                    bindControl()
                    requestRefresh()
                }
            }
        }
    }

    fun isAvailable(): Boolean = initialized.get()

    /**
     * Closes the interval between recording a desired-running command and the
     * periodic liveness pass establishing the AIDL death recipient.
     *
     * Intent factories call this from the main process before Android starts
     * (or reconnects) the remote VPN service. In `:veercore` the client is not
     * initialized, so the call is intentionally a no-op.
     */
    fun onDesiredRunningRequested() {
        if (!initialized.get()) return
        bindControl()
        requestRefresh()
    }

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
        val engineStatus = CoreStateProtocol.decodeEngineStatus(
            state = engineState,
            timestampMs = bundle.getLong(CoreStateProtocol.KEY_STATE_TIMESTAMP),
            operationId = bundle.getString(CoreStateProtocol.KEY_OPERATION_ID),
            message = bundle.getString(CoreStateProtocol.KEY_STATE_MESSAGE),
            machineCode = bundle.getString(CoreStateProtocol.KEY_MACHINE_CODE),
            rootCause = bundle.getString(CoreStateProtocol.KEY_ROOT_CAUSE),
            recoverability = bundle.getString(CoreStateProtocol.KEY_RECOVERABILITY),
        )
        if (MihomoEngine.status.value != engineStatus) {
            MihomoEngine.syncStatus(engineStatus)
        }
        if (MihomoEngine.startupStage.value != startupStage) {
            MihomoEngine.setStartupStage(startupStage)
        }
        if (
            engineState is EngineState.Stopped &&
                !CoreRunStateStore.isDesiredRunning(requireNotNull(appContext))
        ) {
            unbindControl()
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
        control?.let { aidl ->
            val remote = runCatching {
                aidl.call(method, extras ?: Bundle.EMPTY)
            }.onFailure {
                VeerLog.core(
                    "[CoreStateClient] AIDL $method failed: ${it.message}",
                    VeerLog.Level.WARN,
                )
                control = null
                handleBinderDeath("AIDL call failed")
            }.getOrNull()
            if (remote != null) return remote
        }
        return runCatching {
            resolver.call(CoreStateProtocol.URI, method, null, extras)
        }.onFailure {
            VeerLog.core(
                "[CoreStateClient] $method failed: ${it.message}",
                VeerLog.Level.WARN,
            )
        }.getOrNull()
    }

    private fun bindControl() {
        val context = appContext ?: return
        if (
            control != null ||
                controlBound.get() ||
                !controlBinding.compareAndSet(false, true)
        ) return
        val bound = runCatching {
            context.bindService(
                Intent(context, CoreControlService::class.java),
                serviceConnection,
                Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT,
            )
        }.getOrElse {
            VeerLog.core(
                "[CoreStateClient] AIDL bind failed: ${it.message}",
                VeerLog.Level.WARN,
            )
            false
        }
        if (bound) {
            controlBound.set(true)
        } else {
            controlBinding.set(false)
        }
    }

    private fun unbindControl() {
        val context = appContext ?: return
        val binder = control?.asBinder()
        control = null
        controlBinding.set(false)
        runCatching { binder?.unlinkToDeath(deathRecipient, 0) }
        if (controlBound.getAndSet(false)) {
            runCatching { context.unbindService(serviceConnection) }
                .onFailure {
                    VeerLog.core(
                        "[CoreStateClient] AIDL unbind failed: ${it.message}",
                        VeerLog.Level.WARN,
                    )
                }
        }
    }

    private fun handleBinderDeath(reason: String) {
        val context = appContext ?: return
        if (!CoreRunStateStore.isDesiredRunning(context)) {
            binderDeathHandling.set(false)
            unbindControl()
            return
        }
        if (!binderDeathHandling.compareAndSet(false, true)) return
        VeerLog.core("[CoreStateClient] core Binder lost: $reason", VeerLog.Level.ERROR)
        MihomoEngine.setState(
            next = EngineState.Error("Core process connection lost"),
            message = "Core process connection lost",
            machineCode = "CORE_BINDER_DIED",
            rootCause = reason,
            recoverability = EngineRecoverability.RESTART_CORE,
        )
        scope.launch {
            delay(BINDER_REBIND_DELAY_MS)
            controlBinding.set(false)
            bindControl()
        }
    }

    private const val CORE_PROCESS_LIVENESS_INTERVAL_MS = 2_000L
    private const val BINDER_REBIND_DELAY_MS = 250L
}
