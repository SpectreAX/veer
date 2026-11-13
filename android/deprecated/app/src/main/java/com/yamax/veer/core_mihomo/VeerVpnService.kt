package com.yamax.veer.core_mihomo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.yamax.veer.MainActivity
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.ipc.CoreStateClient
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.data.ConfigManager
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.data.PerAppProxyPolicyStore
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import veercore.SocketProtector
import veercore.Veercore
import java.io.File
import java.net.InetAddress
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Sole owner of:
 *   • the tun ParcelFileDescriptor,
 *   • the Mihomo Go runtime's lifetime,
 *   • the foreground service notification.
 *
 * ## Architectural invariants (Phase 1.1 hardening)
 *
 * 1. `Veercore.start(...)` is called ONLY from [bootCore], which runs inside
 *    [serviceScope] and is reached by ACTION_START or the serialized reconnect
 *    path after teardown has fully completed.
 * 2. `Veercore.stop()` is called ONLY from [tearDownCore], which is invoked
 *    by explicit stop, reconnect, profile-switch preparation, and [onDestroy]
 *    lifecycle paths. This includes
 *    the case where `Veercore.start()` returned an error: [startAttempted]
 *    tracks that a start was attempted so partial Mihomo goroutines are cleaned
 *    up even when [coreRunning] was never set to true (native_runtime_contract §9).
 * 3. The tun fd never leaves this class — no public getters, no callbacks that
 *    expose it.
 * 4. [startForegroundImmediately] runs as the FIRST action in [onStartCommand]
 *    for every lifecycle command, preventing the 5-second FGS deadline on
 *    Android 13+ from being tripped.
 * 5. [engineMutex] serialises start and stop so rapid connect/disconnect cannot
 *    produce a second live Go runtime instance or leave the tun orphaned.
 *
 * ## Deadlock analysis
 *
 * [serviceScope] uses [Dispatchers.IO] so [bootCore]'s continuations never
 * resume on the Main thread. [onDestroy] calls `runBlocking { tearDownCore() }`
 * on Main — Main is blocked but only runs [runBlocking]'s own embedded event
 * loop, which has no dependency on the IO thread. The mutex wait inside
 * [tearDownCore] suspends (non-blocking) until [bootCore] releases it on an IO
 * thread. No circular dependency; no deadlock.
 *
 * ## Two-layer teardown timeout
 *
 * `Veercore.stop()` is a blocking JNI call that can hang if the Go runtime is
 * unresponsive. [tearDownCore] uses two independent timeouts:
 *
 * 1. **[STOP_TIMEOUT_MS] (outer, coroutine)** — [withTimeoutOrNull] in [onDestroy]
 *    bounds how long we wait to *acquire* [engineMutex]. Cancels the coroutine at the
 *    mutex suspension point if [bootCore] holds the lock too long (e.g. during a
 *    long-running `Veercore.start()` call). After this timeout [onDestroy] force-closes
 *    the TUN fd directly.
 *
 * 2. **[STOP_JNI_TIMEOUT_MS] (inner, Future.get)** — bounds the JNI call itself
 *    once [tearDownCore] is inside the mutex. `Veercore.stop()` runs on the stable
 *    [VeercoreNativeExecutor] daemon thread; timed [java.util.concurrent.Future.get]
 *    fires even with a blocking JNI frame (unlike [withTimeoutOrNull]). If it times
 *    out the native executor is blocked and the service transitions to [EngineState.Error] (not
 *    [EngineState.Stopped]) — reconnecting into a process with a zombie
 *    `executor.Shutdown()` goroutine would risk Mihomo global-executor split-brain
 *    (runtime_nonrecoverable_states.md Scenario 8). The user must restart the app.
 *
 * Worst-case [onDestroy] duration ≈ [STOP_TIMEOUT_MS] + [STOP_JNI_TIMEOUT_MS] = 9 s.
 */
class VeerVpnService : VpnService() {

    private val serviceJob = SupervisorJob()
    private val exceptionHandler = CoroutineExceptionHandler { _, t ->
        val msg = t.message ?: t.toString()
        VeerLog.vpn("uncaught coroutine exception: $msg", VeerLog.Level.ERROR)
        MihomoEngine.setState(EngineState.Error(msg))
        requestShutdown("uncaught coroutine exception")
    }
    private val serviceScope = CoroutineScope(serviceJob + Dispatchers.IO + exceptionHandler)

    private val engineMutex = Mutex()
    private val shutdownStarted = AtomicBoolean(false)
    private val profileSwitchPreparing = AtomicBoolean(false)
    private val reconnectStarted = AtomicBoolean(false)
    private val restartAfterShutdownRequested = AtomicBoolean(false)
    private val restartAfterDestructionRequested = AtomicBoolean(false)
    private val stopSelfIssued = AtomicBoolean(false)
    private val lateStartCleanupRequired = AtomicBoolean(false)
    private val lateStartCleanupLaunched = AtomicBoolean(false)
    private val shutdownFinalizationLock = Any()

    @Volatile private var tunInterface: ParcelFileDescriptor? = null
    @Volatile private var coreRunning: Boolean = false
    @Volatile private var nonRecoverableStopFailure: Boolean = false
    @Volatile private var latestStartId: Int = 0
    @Volatile private var shutdownStartId: Int = 0

    // Set to true immediately before Veercore.start() so tearDownCore() calls
    // Veercore.stop() even when start() returned an error (partial Mihomo init).
    // Reset to false inside tearDownCore() after stop() completes.
    @Volatile private var startAttempted: Boolean = false
    private var shutdownFinalizeJob: Job? = null

    private var connectivityMonitor: ConnectivityMonitor? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Publish the framework generation before foreground promotion. The
        // delayed stop path uses stopSelfResult(shutdownStartId), so Android
        // atomically rejects an old stop when this newer command has arrived.
        latestStartId = startId
        startForegroundImmediately()

        when (intent?.action) {
            ACTION_STOP -> {
                CoreRunStateStore.setDesiredRunning(applicationContext, false)
                requestShutdown("ACTION_STOP")
                return START_NOT_STICKY
            }
            ACTION_PREPARE_PROFILE_SWITCH -> {
                prepareForProfileSwitch()
                return START_NOT_STICKY
            }
            ACTION_RECONNECT -> {
                requestReconnect()
                return START_STICKY
            }
            else -> {
                if (reconnectStarted.get()) {
                    VeerLog.vpn("[bootCore] start ignored — reconnect already owns the lifecycle")
                    return START_STICKY
                }
                if (shutdownStarted.get()) {
                    val startDisposition = synchronized(shutdownFinalizationLock) {
                        val safelyDrained =
                            MihomoEngine.state.value is EngineState.Stopped &&
                                !coreRunning &&
                                !startAttempted &&
                                !nonRecoverableStopFailure
                        when {
                            safelyDrained && shutdownStarted.compareAndSet(true, false) -> {
                                // Android may deliver a newer START to the same
                                // instance after stopSelfResult() accepted an
                                // older generation but before onDestroy(). That
                                // newer command revives the started service and
                                // cancels the pending destruction. Reopen the
                                // lifecycle gate only after the old runtime and
                                // TUN have fully drained.
                                stopSelfIssued.set(false)
                                restartAfterDestructionRequested.set(false)
                                restartAfterShutdownRequested.set(false)
                                shutdownFinalizeJob?.cancel()
                                shutdownFinalizeJob = null
                                StartDisposition.START_NOW
                            }
                            stopSelfIssued.get() -> {
                                restartAfterDestructionRequested.set(true)
                                restartAfterShutdownRequested.set(false)
                                StartDisposition.WAIT_FOR_REPLACEMENT
                            }
                            else -> {
                                restartAfterShutdownRequested.set(true)
                                StartDisposition.WAIT_FOR_DRAIN
                            }
                        }
                    }
                    when (startDisposition) {
                        StartDisposition.START_NOW -> VeerLog.vpn(
                            "[bootCore] reusing fully drained service for newer start generation",
                        )
                        StartDisposition.WAIT_FOR_REPLACEMENT -> {
                            // Android can deliver a newer START to the old
                            // instance after an earlier stopSelfResult() was
                            // accepted but before onDestroy() runs. Returning
                            // START_STICKY here would mark that old instance as
                            // started again, so onDestroy() might never arrive
                            // and the queued replacement would remain stuck.
                            //
                            // Stop the newest generation as well. onDestroy()
                            // observes restartAfterDestructionRequested and
                            // dispatches a clean replacement service. If an
                            // even newer start is already pending, the atomic
                            // startId check rejects this stop and that command
                            // will make the same decision when delivered.
                            val replacementStopAccepted = stopSelfResult(startId)
                            VeerLog.vpn(
                                "[bootCore] start queued — stopSelf already issued; " +
                                    "replacement stop accepted=$replacementStopAccepted",
                            )
                            if (replacementStopAccepted) {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                    stopForeground(STOP_FOREGROUND_REMOVE)
                                } else {
                                    @Suppress("DEPRECATION")
                                    stopForeground(true)
                                }
                            }
                            return START_NOT_STICKY
                        }
                        StartDisposition.WAIT_FOR_DRAIN -> {
                            VeerLog.vpn(
                                "[bootCore] start queued — waiting for in-progress shutdown to drain",
                            )
                            return START_STICKY
                        }
                    }
                }
                serviceScope.launch { bootCore() }
            }
        }
        return START_STICKY
    }

    // ----- Core boot ----------------------------------------------------------

    private suspend fun bootCore(startNewOperation: Boolean = true) {
        engineMutex.withLock {
            if (shutdownStarted.get()) {
                VeerLog.vpn("[bootCore] ignored — shutdown already in progress")
                return
            }
            if (coreRunning) {
                VeerLog.vpn("[bootCore] ignored — already running")
                return
            }
            if (startNewOperation) MihomoEngine.beginOperation("start")
            MihomoEngine.setStartupStage(StartupStage.PREPARING_CONFIG)
            MihomoEngine.setState(EngineState.Starting)
            VeerLog.vpn("[bootCore] phase=PREPARE_CONFIG")

            // The core process deliberately does not read profile state from
            // Application.onCreate: doing disk work there can exceed Android's
            // ContentProvider publication timeout. Foreground promotion has
            // already happened before this IO-dispatched startup path runs.
            ProfileManager.init(applicationContext)

            // A periodic subscription refresh may have staged a newer validated
            // active config while the previous core was running. Adopt it only
            // at this safe pre-start boundary; the old runtime was never mutated.
            ProfileManager.installPersistedActiveConfigForStart(applicationContext)

            runCatching {
                VeercoreNativeExecutor.call { Veercore.setLogger(VeerLogger()) }
            }
                .onFailure { VeerLog.vpn("[bootCore] setLogger failed: ${it.message}", VeerLog.Level.WARN) }

            // Install socket protector before any network activity. Harmless before
            // TUN is established (protect() has no effect when there is no VPN tunnel);
            // must be set before Veercore.start() so the Go runtime's own sockets are
            // protected from the moment the tunnel comes up.
            runCatching {
                VeercoreNativeExecutor.call {
                    Veercore.setProtector(object : SocketProtector {
                        override fun protect(fd: Int): Boolean =
                            this@VeerVpnService.protect(fd)
                    })
                }
                VeerLog.vpn("[bootCore] socket protector installed")
            }.onFailure {
                VeerLog.vpn("[bootCore] setProtector failed: ${it.message}", VeerLog.Level.WARN)
            }

            val homeDir = runCatching { ConfigManager.prepare(applicationContext) }
                .getOrElse { t ->
                    VeerLog.vpn("[bootCore] ConfigManager.prepare failed: ${t.message}", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error(t.message ?: "config prepare failed"))
                    requestShutdown("config prepare failed")
                    return
                }

            VeerLog.vpn("[bootCore] home=${homeDir.absolutePath}")
            VeerLog.vpn(
                "[bootCore] veer-core ${
                    runCatching {
                        VeercoreNativeExecutor.call { Veercore.version() }
                    }.getOrDefault("?")
                }",
            )

            val configFile = File(homeDir, ConfigManager.BASE_CONFIG)
            val configHash = runCatching {
                MessageDigest.getInstance("SHA-256")
                    .digest(configFile.readBytes())
                    .joinToString("") { "%02x".format(it) }
                    .take(12)
            }.getOrDefault("?")
            VeerLog.vpn("[bootCore] config path=${configFile.absolutePath} size=${configFile.length()}B hash=${configHash}…")

            // Ensure geo databases exist before validation.
            // Primary source: APK assets bundle (works offline, no DNS needed).
            // Fallback: network download from CN-accessible mirrors.
            // TUN is not established yet — all network I/O uses system DNS and
            // normal routing, so socket protection is not required here.
            MihomoEngine.setStartupStage(StartupStage.ENSURING_GEO_DATA)
            VeerLog.vpn("[bootCore] phase=ENSURE_GEO_DB")
            val geoDbReady = GeoDatabaseManager.ensureGeoDb(applicationContext, homeDir)
            if (!geoDbReady) {
                VeerLog.vpn(
                    "[bootCore] geoip.metadb unavailable — refusing startup because DNS fallback and GEOIP rules require local geo data",
                    VeerLog.Level.ERROR,
                )
                MihomoEngine.setState(EngineState.Error("Required GeoIP database is unavailable"))
                requestShutdown("GeoIP database unavailable")
                return
            }

            // Validate config BEFORE establishing TUN using the same Mihomo parser
            // that Start will use. The bundled AAR is versioned with this source,
            // so silently skipping validation for an old binding is not allowed.
            val validateT0 = System.currentTimeMillis()
            MihomoEngine.setStartupStage(StartupStage.VALIDATING_CONFIG)
            VeerLog.vpn("[bootCore] phase=VALIDATE_CONFIG")
            try {
                VeercoreNativeExecutor.call {
                    Veercore.validateConfig(homeDir.absolutePath, ConfigManager.BASE_CONFIG)
                }
                VeerLog.vpn("[bootCore] VALIDATE_CONFIG OK (+${System.currentTimeMillis() - validateT0}ms)")
            } catch (e: Exception) {
                val msg = e.cause?.message ?: e.message ?: e.toString()
                VeerLog.vpn("[bootCore] VALIDATE_CONFIG FAILED (+${System.currentTimeMillis() - validateT0}ms): $msg", VeerLog.Level.ERROR)
                MihomoEngine.setState(EngineState.Error("Config invalid: $msg"))
                requestShutdown("config validation failed")
                return
            }

            // Establish TUN only AFTER config validation succeeds. Any failure above
            // this point exits cleanly with no residual TUN interface.
            MihomoEngine.setStartupStage(StartupStage.ESTABLISHING_TUNNEL)
            VeerLog.vpn("[bootCore] phase=ESTABLISH_TUN")
            val builder = Builder()
                .setSession("Veer")
                .setMtu(VPN_MTU)
                .addAddress(VPN_ADDRESS_V4, 30)
                .addAddress(VPN_ADDRESS_V6, 126)
                .addDnsServer(FAKE_IP_DNS)
                .setBlocking(false)

            applyRoutes(builder)
            applyPerAppRouting(builder)

            // Tell Android this VPN is not metered — prevents apps from entering
            // low-data mode (DataSaver) just because a VPN is active. CMFA also sets this.
            // minSdk is 29 (== Q) so this is always taken; the guard is kept for clarity
            // and to stay correct if minSdk is ever lowered.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

            val pfd = builder.establish()
                ?: run {
                    VeerLog.vpn("[bootCore] tun establish() returned null", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error("tun establish failed"))
                    requestShutdown("tun establish failed")
                    return
                }
            tunInterface = pfd
            VeerLog.vpn("[bootCore] ESTABLISH_TUN OK fd=${pfd.fd}")

            // startAttempted must be set BEFORE the call so that if the JNI
            // call panics and the panic recovery returns an error, tearDownCore
            // still calls Veercore.stop() to clean up any partially-initialized
            // Mihomo goroutines. See native_runtime_contract.md §9 (V1 fix).
            val startT0 = System.currentTimeMillis()
            MihomoEngine.setStartupStage(StartupStage.STARTING_RUNTIME)
            VeerLog.vpn("[bootCore] phase=START_RUNTIME")
            startAttempted = true
            runCatching {
                VeercoreNativeExecutor.call {
                    Veercore.start(homeDir.absolutePath, ConfigManager.BASE_CONFIG, pfd.fd)
                }
            }
                .onFailure { t ->
                    val msg = t.cause?.message ?: t.message ?: t.toString()
                    if (shutdownStarted.get()) {
                        // The outer stop timeout may close the JVM TUN while a
                        // slow start still owns engineMutex. Accessing that fd
                        // then reports "Already closed"; this is cancellation,
                        // not a separate runtime failure. The authoritative
                        // shutdown/late-cleanup path still sees startAttempted.
                        VeerLog.vpn(
                            "[bootCore] START_RUNTIME aborted by shutdown" +
                                " (+${System.currentTimeMillis() - startT0}ms): $msg",
                            VeerLog.Level.WARN,
                        )
                        return
                    }
                    VeerLog.vpn("[bootCore] START_RUNTIME FAILED (+${System.currentTimeMillis() - startT0}ms): $msg", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error(msg))
                    requestShutdown("runtime start failed")
                    return
                }
            VeerLog.vpn("[bootCore] START_RUNTIME OK (+${System.currentTimeMillis() - startT0}ms)")

            coreRunning = true
            MihomoEngine.setStartupStage(StartupStage.VERIFYING_RUNTIME)
            VeerLog.vpn("[bootCore] phase=VERIFY_RUNTIME")
            val readinessT0 = System.currentTimeMillis()
            val readiness = RuntimeReadinessVerifier(
                maxAttempts = READINESS_MAX_ATTEMPTS,
                retryDelayMs = READINESS_RETRY_DELAY_MS,
                probe = {
                    val nativeReady = runCatching {
                        VeercoreNativeExecutor.call {
                            Veercore.getDashboardRoutingStats("").coreRunning
                        }
                    }.getOrDefault(false)
                    val controllerReady = MihomoRepository.get().controllerReady()
                    RuntimeReadinessEvidence(nativeReady, controllerReady)
                },
                isCancelled = shutdownStarted::get,
            ).await()
            when (readiness) {
                is RuntimeReadinessResult.Ready -> VeerLog.vpn(
                    "[bootCore] VERIFY_RUNTIME OK attempts=${readiness.attempts}" +
                        " (+${System.currentTimeMillis() - readinessT0}ms)",
                )
                is RuntimeReadinessResult.Cancelled -> VeerLog.vpn(
                    "[bootCore] VERIFY_RUNTIME cancelled by shutdown after " +
                        "${readiness.attempts} attempt(s)",
                    VeerLog.Level.WARN,
                )
                is RuntimeReadinessResult.TimedOut -> {
                    val evidence = readiness.lastEvidence
                    val message = "runtime readiness timed out " +
                        "(native=${evidence.nativeRuntimeReady}, " +
                        "controller=${evidence.controllerReady})"
                    VeerLog.vpn("[bootCore] VERIFY_RUNTIME FAILED: $message", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error(message))
                    requestShutdown("runtime readiness failed")
                    return
                }
            }
            if (shutdownStarted.get()) {
                // ACTION_STOP may arrive while the non-cancellable JNI start is
                // in progress. The shutdown coroutine either remains queued on
                // this mutex or, after its bounded wait expires, launches the
                // single late-cleanup owner. Never publish a transient Running
                // state after shutdown was requested.
                VeerLog.vpn(
                    "[bootCore] start completed after shutdown request — teardown remains authoritative",
                    VeerLog.Level.WARN,
                )
            } else {
                VeerLog.vpn("[bootCore] mihomo core started")
                val allNetworksLostHandler: () -> Unit = {
                    AppStateRepository.updateConnectivity(0, false)
                    VeerLog.connectivity(
                        "onAllNetworksLost coreRunning=$coreRunning " +
                            "shutdownStarted=${shutdownStarted.get()}",
                    )
                    if (coreRunning && !shutdownStarted.get()) {
                        // Connectivity loss is not a core-lifecycle failure. Keep
                        // TUN and Mihomo alive so Wi-Fi/cellular handoff can recover
                        // through setUnderlyingNetworks and UpdateSystemDNS without
                        // an expensive Stop/Start cycle.
                        runCatching { setUnderlyingNetworks(null) }
                            .onFailure {
                                VeerLog.connectivity(
                                    "failed to clear underlying networks: ${it.message}",
                                    VeerLog.Level.WARN,
                                )
                            }
                        VeerLog.connectivity("all networks lost — runtime retained for recovery")
                    } else {
                        VeerLog.connectivity("onAllNetworksLost ignored — teardown in progress")
                    }
                }
                debugAllNetworksLostCallback = allNetworksLostHandler
                val monitor = ConnectivityMonitor(
                    context = this,
                    onUnderlyingNetworksChanged = { networks ->
                        setUnderlyingNetworks(networks)
                        AppStateRepository.updateConnectivity(networks.size, true)
                    },
                    onSystemDnsChanged = { servers ->
                        serviceScope.launch {
                            runCatching {
                                VeercoreNativeExecutor.call {
                                    Veercore.updateSystemDNS(servers.joinToString(","))
                                }
                            }.onFailure {
                                VeerLog.connectivity(
                                    "system DNS update failed: ${it.message}",
                                    VeerLog.Level.WARN,
                                )
                            }
                        }
                    },
                    onAllNetworksLost = allNetworksLostHandler,
                )
                val initialConnectivity = monitor.captureCurrentSnapshot()
                runCatching {
                    val networks = initialConnectivity.networks
                    setUnderlyingNetworks(networks.takeIf { it.isNotEmpty() })
                    AppStateRepository.updateConnectivity(
                        physicalNetworksAvailable = networks.size,
                        hasInternet = networks.isNotEmpty(),
                    )
                    VeercoreNativeExecutor.call {
                        Veercore.updateSystemDNS(
                            initialConnectivity.dnsServers.joinToString(","),
                        )
                    }
                }.onSuccess {
                    VeerLog.connectivity(
                        "initial network/DNS synchronization complete before Running " +
                            "(networks=${initialConnectivity.networks.size}, " +
                            "dns=${initialConnectivity.dnsServers.size})",
                    )
                }.onFailure {
                    VeerLog.connectivity(
                        "initial network/DNS synchronization failed: ${it.message}",
                        VeerLog.Level.WARN,
                    )
                }
                connectivityMonitor = monitor.also { it.start(initialConnectivity) }

                runCatching { ProfileSelectionStore.restoreActive(MihomoRepository.get()) }
                    .onFailure {
                        VeerLog.profile(
                            "failed to restore profile selections: ${it.message}",
                            VeerLog.Level.WARN,
                        )
                    }
                runCatching { ProfileManager.markActiveAsLastKnownGood(applicationContext) }
                    .onFailure {
                        VeerLog.profile(
                            "failed to persist last-known-good snapshot: ${it.message}",
                            VeerLog.Level.WARN,
                        )
                    }
                MihomoEngine.setStartupStage(StartupStage.READY)
                MihomoEngine.setState(EngineState.Running)
                launchWatchdog()
                launchAutoRecovery()
            }
        }

    }

    // ----- TUN routing --------------------------------------------------------

    /**
     * Installs the tun routing table while keeping local address space on the
     * underlying network when [BYPASS_LAN] is enabled.
     *
     * API 33+ installs IPv4/IPv6 default routes and uses
     * [VpnService.Builder.excludeRoute] for RFC1918, IPv4 link-local/multicast,
     * IPv6 ULA and IPv6 link-local ranges. API 29–32 installs their exact CIDR
     * complements because `excludeRoute()` is unavailable. With bypass
     * disabled, both address families use ordinary default routes.
     */
    private fun applyRoutes(builder: Builder) {
        val supportsExcludeRoute = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        val plan = VpnRoutePolicy.build(
            bypassLan = BYPASS_LAN,
            supportsExcludeRoute = supportsExcludeRoute,
        )
        for (route in plan.included) {
            builder.addRoute(route.address, route.prefixLength)
        }
        if (supportsExcludeRoute) {
            for (route in plan.excluded) {
                builder.excludeRoute(
                    IpPrefix(
                        InetAddress.getByName(route.address),
                        route.prefixLength,
                    ),
                )
            }
        }
        VeerLog.vpn(
            "[bootCore] routes: included=${plan.included.size} " +
                "excluded=${plan.excluded.size} bypassLan=$BYPASS_LAN " +
                "excludeRouteApi=$supportsExcludeRoute api=${Build.VERSION.SDK_INT}",
        )
    }

    /**
     * Applies the persisted per-app routing snapshot to this new TUN.
     *
     * Android does not permit allow-list and deny-list calls on the same
     * [Builder], so [PerAppVpnPolicy] resolves and validates the complete plan
     * before this method mutates the Builder. Veer's package is always outside
     * the tunnel: it is explicitly denied in all/bypass mode and is absent from
     * the allow-list in selected-only mode.
     */
    private fun applyPerAppRouting(builder: Builder) {
        val policy = PerAppProxyPolicyStore.read(applicationContext)
        val plan = PerAppVpnPolicy.build(
            policy = policy,
            ownPackageName = packageName,
            isInstalled = ::isPackageInstalled,
        )

        if (plan.usedFailSafe) {
            VeerLog.vpn(
                "[bootCore] per-app ${plan.requestedMode} has no installed selections; " +
                    "falling back to ${plan.effectiveMode}",
                VeerLog.Level.WARN,
            )
        }
        if (plan.unavailablePackages.isNotEmpty()) {
            VeerLog.vpn(
                "[bootCore] per-app skipped ${plan.unavailablePackages.size} unavailable package(s)",
                VeerLog.Level.WARN,
            )
        }

        if (plan.effectiveMode == PerAppProxyMode.ONLY_SELECTED) {
            var applied = 0
            plan.allowedPackages.forEach { selectedPackage ->
                runCatching { builder.addAllowedApplication(selectedPackage) }
                    .onSuccess { applied += 1 }
                    .onFailure {
                        VeerLog.vpn(
                            "[bootCore] addAllowedApplication($selectedPackage) failed: ${it.message}",
                            VeerLog.Level.WARN,
                        )
                    }
            }
            if (applied == 0) {
                // All calls failed before any allow-list entry was installed.
                // Exclude Veer and retain the ordinary all-apps behavior rather
                // than establishing a tunnel that carries no application.
                runCatching { builder.addDisallowedApplication(packageName) }
                    .onFailure {
                        VeerLog.vpn(
                            "[bootCore] per-app fail-safe exclusion failed: ${it.message}",
                            VeerLog.Level.WARN,
                        )
                    }
                VeerLog.vpn(
                    "[bootCore] per-app allow-list could not be applied; using all-apps fail-safe",
                    VeerLog.Level.WARN,
                )
            }
        } else {
            plan.disallowedPackages.forEach { selectedPackage ->
                runCatching { builder.addDisallowedApplication(selectedPackage) }
                    .onFailure {
                        VeerLog.vpn(
                            "[bootCore] addDisallowedApplication($selectedPackage) failed: ${it.message}",
                            VeerLog.Level.WARN,
                        )
                    }
            }
        }

        VeerLog.vpn(
            "[bootCore] per-app mode=${plan.effectiveMode} " +
                "allowed=${plan.allowedPackages.size} " +
                "disallowed=${plan.disallowedPackages.size}",
        )
    }

    @Suppress("DEPRECATION")
    private fun isPackageInstalled(candidate: String): Boolean =
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getApplicationInfo(
                    candidate,
                    PackageManager.ApplicationInfoFlags.of(0),
                )
            } else {
                packageManager.getApplicationInfo(candidate, 0)
            }
        }.isSuccess

    // ----- Watchdog -----------------------------------------------------------

    /**
     * Polls the Mihomo REST API every [WATCHDOG_INTERVAL_MS]. A null response
     * means the process-internal HTTP server has gone away, which indicates a
     * Go runtime crash or hang. On detection the service transitions to Error
     * and calls [requestShutdown] so the runtime and TUN are released before
     * the service asks Android to destroy it.
     */
    private fun launchWatchdog() {
        serviceScope.launch {
            val failureTracker = WatchdogFailureTracker(WATCHDOG_FAILURE_THRESHOLD)
            delay(effectiveWatchdogInitialDelayMs)
            while (isActive && coreRunning) {
                val version = runCatching { MihomoRepository.get().version() }.getOrNull()
                if (!coreRunning) break

                val failuresBeforeProbe = failureTracker.consecutiveFailures
                val shouldShutdown = failureTracker.record(reachable = version != null)
                if (version == null) {
                    VeerLog.watchdog(
                        "Mihomo API probe failed ${failureTracker.consecutiveFailures}/$WATCHDOG_FAILURE_THRESHOLD",
                        VeerLog.Level.WARN,
                    )
                    if (shouldShutdown) {
                        VeerLog.watchdog(
                            "Mihomo API unreachable after $WATCHDOG_FAILURE_THRESHOLD consecutive probes — requesting shutdown",
                            VeerLog.Level.ERROR,
                        )
                        MihomoEngine.setState(EngineState.Error("watchdog: core API unreachable"))
                        requestShutdown("watchdog failure")
                        break
                    }
                } else if (failuresBeforeProbe > 0) {
                    VeerLog.watchdog("Mihomo API recovered after $failuresBeforeProbe failed probe(s)")
                }
                delay(effectiveWatchdogIntervalMs)
            }
            VeerLog.watchdog("loop exited isActive=$isActive coreRunning=$coreRunning")
        }
    }

    /**
     * Supervises the actual proxy exit without taking ownership of core/TUN
     * lifecycle. Controller failures remain the watchdog's responsibility;
     * only repeated exit failures trigger node recovery.
     */
    private fun launchAutoRecovery() {
        serviceScope.launch {
            val testProbe = testAutoRecoveryInternetProbe
            val manager = if (testProbe != null) {
                AutoRecoveryManager(
                    context = applicationContext,
                    failureThreshold = effectiveAutoRecoveryFailureThreshold,
                    maxCandidates = effectiveAutoRecoveryMaxCandidates,
                    internetProbe = { testProbe() },
                )
            } else {
                AutoRecoveryManager(
                    context = applicationContext,
                    failureThreshold = effectiveAutoRecoveryFailureThreshold,
                    maxCandidates = effectiveAutoRecoveryMaxCandidates,
                )
            }
            delay(effectiveAutoRecoveryInitialDelayMs)
            while (isActive && coreRunning) {
                when (val result = manager.checkAndRecover()) {
                    AutoRecoveryResult.Healthy -> Unit
                    is AutoRecoveryResult.Degraded -> VeerLog.watchdog(
                        "proxy exit failed ${result.failures}/$effectiveAutoRecoveryFailureThreshold",
                        VeerLog.Level.WARN,
                    )
                    is AutoRecoveryResult.Suppressed -> VeerLog.watchdog(
                        "auto recovery suppressed: ${result.reason}",
                        VeerLog.Level.WARN,
                    )
                    is AutoRecoveryResult.Recovered -> VeerLog.watchdog(
                        "auto recovery switched ${result.group}: " +
                            "${result.previous} → ${result.selected}",
                        VeerLog.Level.INFO,
                    )
                    is AutoRecoveryResult.Unrecoverable -> {
                        VeerLog.watchdog(
                            "auto recovery exhausted group=${result.group} " +
                                "attempted=${result.attempted.size} " +
                                "selectionRestored=${result.selectionRestored}; " +
                                "keeping VPN running for the next probe",
                            VeerLog.Level.WARN,
                        )
                        testAutoRecoveryExhaustedCallback?.invoke()
                    }
                }
                delay(effectiveAutoRecoveryIntervalMs)
            }
            VeerLog.watchdog("auto recovery loop exited isActive=$isActive coreRunning=$coreRunning")
        }
    }

    // ----- Teardown -----------------------------------------------------------

    /**
     * Stops Mihomo and releases the TUN without destroying this foreground
     * service. Android may delay [onDestroy] for many seconds after [stopSelf],
     * so profile switching must not use service destruction as its readiness
     * signal. Retaining this instance also prevents a replacement start from
     * racing a pending destruction callback.
     */
    private fun prepareForProfileSwitch() {
        if (shutdownStarted.get()) {
            VeerLog.vpn("[profileSwitch] ignored — permanent shutdown already in progress")
            return
        }
        if (reconnectStarted.get()) {
            VeerLog.vpn("[profileSwitch] ignored — reconnect already in progress")
            return
        }
        if (!profileSwitchPreparing.compareAndSet(false, true)) {
            VeerLog.vpn("[profileSwitch] ignored — preparation already in progress")
            return
        }

        VeerLog.vpn("[profileSwitch] stopping core and releasing TUN")
        MihomoEngine.beginOperation("profile_switch")
        MihomoEngine.setState(EngineState.Stopping)
        serviceScope.launch {
            try {
                tearDownCore(finalizeState = true)
                VeerLog.vpn("[profileSwitch] ready — service retained for restart")
            } catch (t: Throwable) {
                VeerLog.vpn(
                    "[profileSwitch] teardown failed: ${t.javaClass.simpleName}: ${t.message}",
                    VeerLog.Level.ERROR,
                )
                tearDownTun()
                MihomoEngine.setState(EngineState.Error(t.message ?: "profile switch teardown failed"))
            } finally {
                profileSwitchPreparing.set(false)
            }
        }
    }

    /**
     * Performs a user-requested reconnect inside the existing service instance.
     *
     * Unlike separate STOP and START commands, this path does not wait for
     * Android's delayed service destruction. The existing teardown, boot,
     * mutex, and native-stop timeout contracts remain the source of truth.
     */
    private fun requestReconnect() {
        if (shutdownStarted.get() || profileSwitchPreparing.get()) {
            VeerLog.vpn("[reconnect] ignored — another lifecycle operation is in progress")
            return
        }
        if (!reconnectStarted.compareAndSet(false, true)) {
            VeerLog.vpn("[reconnect] ignored — reconnect already in progress")
            return
        }
        if (!coreRunning || MihomoEngine.state.value !is EngineState.Running) {
            reconnectStarted.set(false)
            VeerLog.vpn("[reconnect] ignored — runtime is not running")
            return
        }

        val reconnectT0 = System.currentTimeMillis()
        VeerLog.vpn("[reconnect] beginning in-service reconnect")
        MihomoEngine.beginOperation("reconnect")
        MihomoEngine.setState(EngineState.Stopping)
        serviceScope.launch {
            try {
                // Avoid a transient, user-clickable Stopped frame. bootCore()
                // publishes Starting only after teardown has fully drained.
                tearDownCore(finalizeState = false)
                if (
                    nonRecoverableStopFailure ||
                    MihomoEngine.state.value is EngineState.Error ||
                    shutdownStarted.get()
                ) {
                    VeerLog.vpn(
                        "[reconnect] restart suppressed because teardown was not recoverable",
                        VeerLog.Level.ERROR,
                    )
                    return@launch
                }
                bootCore(startNewOperation = false)
                VeerLog.vpn(
                    "[reconnect] completed state=${MihomoEngine.state.value}" +
                        " (+${System.currentTimeMillis() - reconnectT0}ms)",
                )
            } catch (t: Throwable) {
                VeerLog.vpn(
                    "[reconnect] failed: ${t.javaClass.simpleName}: ${t.message}",
                    VeerLog.Level.ERROR,
                )
                MihomoEngine.setState(EngineState.Error(t.message ?: "reconnect failed"))
                requestShutdown("reconnect failed")
            } finally {
                reconnectStarted.set(false)
            }
        }
    }

    /**
     * Begins the single explicit shutdown path.
     *
     * An active VPN keeps its service bound, so stopSelf() alone is not guaranteed
     * to deliver onDestroy(). Teardown therefore has to happen first. The atomic
     * gate makes repeated STOP, watchdog, connectivity, and revoke signals idempotent;
     * [engineMutex] still serializes teardown against an in-flight start.
     */
    private fun requestShutdown(reason: String) {
        if (MihomoEngine.state.value is EngineState.Error) {
            // StateFlow is conflated. Give observers one scheduling turn to
            // receive the actionable error before Stopping replaces it.
            serviceScope.launch {
                delay(ERROR_VISIBILITY_MS)
                beginShutdown(reason)
            }
            return
        }
        beginShutdown(reason)
    }

    private fun beginShutdown(reason: String) {
        if (!shutdownStarted.compareAndSet(false, true)) {
            VeerLog.vpn("[stop] $reason ignored — shutdown already in progress")
            return
        }

        shutdownStartId = latestStartId
        lateStartCleanupRequired.set(false)
        lateStartCleanupLaunched.set(false)
        VeerLog.vpn("[stop] $reason — beginning serialized teardown")
        MihomoEngine.beginOperation("stop")
        MihomoEngine.setState(EngineState.Stopping)
        serviceScope.launch {
            var restartAfterDrain = false
            try {
                // Bound both mutex acquisition and native teardown. Android may
                // delay onDestroy indefinitely for a bound VPN service, so this
                // explicit path must reach a truthful terminal state itself.
                val completed = withTimeoutOrNull(effectiveStopTimeoutMs) {
                    tearDownCore(finalizeState = false)
                    true
                } ?: false
                if (!completed) {
                    lateStartCleanupRequired.set(true)
                    VeerLog.vpn(
                        "[stop] teardown timed out after ${effectiveStopTimeoutMs}ms — forcing TUN close",
                        VeerLog.Level.ERROR,
                    )
                    tearDownTun()
                    launchLateStartCleanup()
                }
                // Core and TUN are already fully released. Preserve Error when
                // the JNI stop latch timed out: that process may still contain
                // a zombie Shutdown goroutine and must not offer reconnect.
                if (!nonRecoverableStopFailure && completed) {
                    MihomoEngine.setState(EngineState.Stopped)
                    restartAfterDrain = claimQueuedStartAfterSafeDrain()
                }
            } catch (t: Throwable) {
                VeerLog.vpn(
                    "[stop] tearDownCore threw ${t.javaClass.simpleName}: ${t.message} — forcing tun teardown",
                    VeerLog.Level.ERROR,
                )
                MihomoEngine.setState(EngineState.Error(t.message ?: "teardown failed"))
                tearDownTun()
            } finally {
                if (restartAfterDrain || !shutdownStarted.get()) {
                    VeerLog.vpn("[stop] teardown finished — retaining service for queued start")
                    if (restartAfterDrain) {
                        bootCore()
                    }
                } else {
                    VeerLog.vpn("[stop] teardown finished — scheduling foreground-service stop")
                    scheduleForegroundServiceStop()
                }
            }
        }
    }

    /**
     * Owns cleanup when the bounded shutdown could not acquire [engineMutex]
     * before an in-flight native start returned. The timeout path is the only
     * producer; this avoids the old timing race where boot and shutdown each
     * expected the other coroutine to perform the second cleanup pass.
     */
    private fun launchLateStartCleanup() {
        if (!lateStartCleanupLaunched.compareAndSet(false, true)) return
        serviceScope.launch {
            var resumeQueuedStart = false
            try {
                VeerLog.vpn("[stop] waiting for in-flight start before late cleanup")
                withContext(NonCancellable) {
                    tearDownCore(finalizeState = false)
                    lateStartCleanupRequired.set(false)
                    if (!nonRecoverableStopFailure) {
                        MihomoEngine.setState(EngineState.Stopped)
                        resumeQueuedStart = claimQueuedStartAfterSafeDrain()
                    }
                }
                if (resumeQueuedStart) {
                    VeerLog.vpn("[stop] resuming queued start after late cleanup")
                    bootCore()
                } else if (shutdownStarted.get()) {
                    VeerLog.vpn("[stop] late cleanup complete — scheduling service stop")
                    scheduleForegroundServiceStop()
                }
            } catch (t: Throwable) {
                VeerLog.vpn(
                    "[stop] late cleanup failed: ${t.message}",
                    VeerLog.Level.ERROR,
                )
                MihomoEngine.setState(
                    next = EngineState.Error(t.message ?: "late cleanup failed"),
                    machineCode = "CORE_LATE_CLEANUP_FAILED",
                    rootCause = t.javaClass.name,
                    recoverability = EngineRecoverability.RESTART_APP,
                )
                tearDownTun()
            } finally {
                lateStartCleanupLaunched.set(false)
            }
        }
    }

    /** Keeps foreground ownership during the short same-instance reuse window. */
    private fun scheduleForegroundServiceStop() {
        shutdownFinalizeJob?.cancel()
        shutdownFinalizeJob = serviceScope.launch {
            delay(SHUTDOWN_DESTROY_GRACE_MS)
            val stopAccepted = synchronized(shutdownFinalizationLock) {
                if (shutdownStarted.get() && !coreRunning && !startAttempted) {
                    // stopSelfResult atomically rejects an obsolete stop when a
                    // newer START generation has already reached the service.
                    stopSelfResult(shutdownStartId).also { stopSelfIssued.set(it) }
                } else {
                    null
                }
            }
            when (stopAccepted) {
                false -> VeerLog.vpn(
                    "[stop] service destruction cancelled by newer startId",
                )
                true -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                null -> Unit
            }
        }
    }

    /**
     * Claims a START that arrived while teardown was still active.
     *
     * This may only be called after the old runtime and TUN are fully drained.
     * A JNI stop timeout permanently blocks same-process restart.
     */
    private fun claimQueuedStartAfterSafeDrain(): Boolean {
        return synchronized(shutdownFinalizationLock) {
            if (!restartAfterShutdownRequested.get() || stopSelfIssued.get()) {
                return@synchronized false
            }
            val safelyDrained =
                MihomoEngine.state.value is EngineState.Stopped &&
                    !coreRunning &&
                    !startAttempted &&
                    !nonRecoverableStopFailure
            if (!safelyDrained || !shutdownStarted.compareAndSet(true, false)) {
                return@synchronized false
            }

            restartAfterShutdownRequested.set(false)
            shutdownFinalizeJob?.cancel()
            shutdownFinalizeJob = null
            true
        }
    }

    /**
     * Acquires [engineMutex] before touching runtime state so a concurrent
     * [bootCore] cannot observe a partially-torn-down service.
     *
     * Calls Veercore.stop() if [startAttempted] OR [coreRunning] is true:
     * - [coreRunning] true  → normal running → stop is mandatory.
     * - [startAttempted] true but [coreRunning] false → start() returned an
     *   error after partially initializing Mihomo goroutines → stop() cleans
     *   them up. [SPECULATIVE — unverified at Go source level] Veercore.stop()
     *   has its own defer recover() so calling it on partially-initialized
     *   state is expected to be safe (native_runtime_contract.md §9).
     *
     * Terminal state:
     * - When [finalizeState] is true, normal completion publishes
     *   [EngineState.Stopped].
     * - When false, the caller owns the next state: explicit shutdown publishes
     *   Stopped after the bounded call; fast reconnect moves directly to Starting.
     * - JNI timeout ([STOP_JNI_TIMEOUT_MS] fires before Veercore.stop() returns) →
     *   [EngineState.Error]. The native executor remains blocked; the Go runtime may
     *   still be executing executor.Shutdown(). A subsequent Veercore.start() in this
     *   process risks Mihomo global executor split-brain (Scenario 8,
     *   runtime_nonrecoverable_states.md). Error state prevents the UI from offering
     *   a seamless reconnect; the user must force-stop and reopen the app.
     *   (Stopping → Error is the documented legal transition for this failure path —
     *   see runtime_invariants.md §3.2.)
     */
    private suspend fun tearDownCore(finalizeState: Boolean = true) {
        val t0 = System.currentTimeMillis()
        fun elapsed() = System.currentTimeMillis() - t0

        VeerLog.vpn("[tearDownCore] waiting for engineMutex (coreRunning=$coreRunning startAttempted=$startAttempted)")
        engineMutex.withLock {
            VeerLog.vpn("[tearDownCore] engineMutex acquired (+${elapsed()}ms)")

            // Clear coreRunning BEFORE stopping the connectivity monitor so that any
            // in-flight onAllNetworksLost / onAvailable callback that arrives on a Binder
            // thread after unregisterNetworkCallback() returns sees coreRunning=false and
            // takes the "teardown in progress" branch instead of calling
            // request another shutdown during an already-in-progress teardown.
            val needsStop = coreRunning || startAttempted
            coreRunning = false

            // Debug instrumentation can install a one-shot probe to exercise the
            // exact teardown window after coreRunning is cleared but before the
            // connectivity callback is unregistered. Keeping the trigger here makes
            // the lifecycle test deterministic without delaying production teardown.
            val connectivityTeardownProbe = testBeforeConnectivityMonitorStop
            testBeforeConnectivityMonitorStop = null
            connectivityTeardownProbe?.invoke()

            val monT0 = System.currentTimeMillis()
            VeerLog.vpn("[tearDownCore] stopping connectivityMonitor")
            // 1.A.3 probes — fine-grained "step=X" markers narrow which un-runCatching'd
            // call threw when onDestroy's catch fires. Last "step=" line before the
            // [onDestroy] tearDownCore threw … line identifies the culprit.
            VeerLog.vpn("[tearDownCore] step=connectivityMonitor.stop()")
            connectivityMonitor?.stop()
            connectivityMonitor = null
            debugAllNetworksLostCallback = null
            VeerLog.vpn("[tearDownCore] step=AppStateRepository.updateConnectivity(0,false)")
            AppStateRepository.updateConnectivity(0, false)
            VeerLog.vpn("[tearDownCore] connectivityMonitor stopped (+${System.currentTimeMillis() - monT0}ms)")

            if (needsStop) {
                // Run Veercore.stop() on the stable native daemon executor so its
                // JNI frame cannot block this coroutine indefinitely and repeated
                // lifecycle calls do not attach a new Go goroutine to every
                // one-off Java Thread.
                val stopT0 = System.currentTimeMillis()
                VeerLog.vpn(
                    "[tearDownCore] submitting Veercore.stop() to native executor " +
                        "(jniTimeout=${STOP_JNI_TIMEOUT_MS}ms)",
                )
                val stopFuture = VeercoreNativeExecutor.submit {
                    runCatching { Veercore.stop() }
                        .onSuccess {
                            VeerLog.vpn("[tearDownCore] Veercore.stop() OK (+${System.currentTimeMillis() - stopT0}ms)")
                        }
                        .onFailure { t ->
                            VeerLog.vpn(
                                "[tearDownCore] Veercore.stop() threw ${t.javaClass.simpleName}: ${t.message}" +
                                    " (+${System.currentTimeMillis() - stopT0}ms)",
                                VeerLog.Level.WARN,
                            )
                        }
                }

                VeerLog.vpn("[tearDownCore] step=future.get(${STOP_JNI_TIMEOUT_MS}ms)")
                val jniCompleted = try {
                    stopFuture.get(STOP_JNI_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    true
                } catch (_: TimeoutException) {
                    false
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    false
                }
                VeerLog.vpn("[tearDownCore] step=future.get returned completed=$jniCompleted")
                if (!jniCompleted) {
                    nonRecoverableStopFailure = true
                    // The native executor is now blocked. Per runtime_nonrecoverable_states.md
                    // Scenario 8 + operational recommendation: any subsequent Veercore.start()
                    // in this process risks split-brain between the orphaned executor.Shutdown()
                    // goroutine and a new executor.ApplyConfig() call. The service must
                    // transition to Error (not Stopped) so the user is not offered a seamless
                    // reconnect. The user must force-stop and reopen the app (process restart).
                    VeerLog.vpn(
                        "[tearDownCore] Veercore.stop() timed out after ${STOP_JNI_TIMEOUT_MS}ms" +
                            " — native executor blocked; Go executor.Shutdown() goroutine may still be" +
                            " running. Reconnecting in this process risks Mihomo split-brain." +
                            " Restart the app before reconnecting.",
                        VeerLog.Level.ERROR,
                    )
                }
                startAttempted = false
                VeerLog.vpn("[tearDownCore] coreRunning=false startAttempted=false (+${elapsed()}ms)")
            } else {
                VeerLog.vpn("[tearDownCore] skipping Veercore.stop() — core was not started")
            }

            // Detach the logger after the core is down so winding-down Go goroutines
            // cannot deliver log events into a GC'd JVM reference.
            if (!nonRecoverableStopFailure) {
                runCatching {
                    VeercoreNativeExecutor.call { Veercore.setLogger(null) }
                }.onFailure {
                    VeerLog.vpn(
                        "[tearDownCore] setLogger(null) threw: ${it.message}",
                        VeerLog.Level.WARN,
                    )
                }
            }

            val tunT0 = System.currentTimeMillis()
            VeerLog.vpn("[tearDownCore] calling tearDownTun()")
            tearDownTun()
            VeerLog.vpn("[tearDownCore] tearDownTun() done (+${System.currentTimeMillis() - tunT0}ms)")

            VeerLog.vpn("[tearDownCore] complete — total teardown ${elapsed()}ms")
            VeerLog.vpn("VeerVpnService destroyed")

            // Per runtime_nonrecoverable_states.md operational recommendation:
            // a timed-out stop leaves orphaned Go goroutines in executor.Shutdown().
            // Transition to Error rather than Stopped so the UI does not offer a
            // seamless reconnect into a potentially split-brained process.
            // Stopping→Error is a legal transition for this specific failure path
            // (runtime_invariants.md §3.2 and §3.5).
            val terminalState = when {
                nonRecoverableStopFailure -> "Error"
                finalizeState -> "Stopped"
                else -> "Stopping (awaiting caller finalization)"
            }
            VeerLog.vpn("[tearDownCore] step=setState($terminalState)")
            if (nonRecoverableStopFailure) {
                MihomoEngine.setState(
                    next = EngineState.Error("VPN stop timed out — restart the app to reconnect"),
                    machineCode = "CORE_STOP_TIMEOUT",
                    recoverability = EngineRecoverability.RESTART_APP,
                )
            } else if (finalizeState) {
                MihomoEngine.setState(EngineState.Stopped)
            }
        }
    }

    /**
     * Routes teardown through [tearDownCore] which acquires [engineMutex], ensuring
     * no concurrent [bootCore] can race the shutdown.
     *
     * See class-level KDoc for the two-layer timeout design. [tearDownTun] is invoked
     * from a `finally` so the tun fd is released on every exit path:
     * - normal completion — [tearDownCore] already closed it; the finally is a no-op;
     * - Layer-1 timeout (null result from [withTimeoutOrNull], [bootCore] held the mutex
     *   past [STOP_TIMEOUT_MS] so [tearDownCore] never ran) — the finally closes it;
     * - [tearDownCore] threw before reaching its own [tearDownTun] — the catch sets
     *   [EngineState.Error] and the finally still closes it, preventing a half-torn-down
     *   "VpnService up, fd open, core dead" black-hole state.
     */
    override fun onDestroy() {
        try {
            VeerLog.vpn("[onDestroy] entered coreRunning=$coreRunning startAttempted=$startAttempted")
            if (shutdownStarted.compareAndSet(false, true)) {
                VeerLog.vpn("[onDestroy] system lifecycle initiated shutdown")
                MihomoEngine.beginOperation("system_stop")
                MihomoEngine.setState(EngineState.Stopping)
            } else {
                VeerLog.vpn("[onDestroy] explicit shutdown already initiated")
            }

            val destroyT0 = System.currentTimeMillis()
            try {
                runBlocking {
                    val timeoutMs = effectiveStopTimeoutMs
                    VeerLog.vpn("[onDestroy] runBlocking: withTimeoutOrNull(${timeoutMs}ms) bounding mutex-wait")
                    val completed = withTimeoutOrNull(timeoutMs) { tearDownCore() }
                    val elapsed = System.currentTimeMillis() - destroyT0
                    if (completed == null) {
                        VeerLog.vpn(
                            "[onDestroy] TIMEOUT: tearDownCore mutex-wait exceeded ${timeoutMs}ms (elapsed ${elapsed}ms)" +
                                " — bootCore likely still holding lock",
                            VeerLog.Level.WARN,
                        )
                        MihomoEngine.setState(EngineState.Stopped)
                    } else {
                        VeerLog.vpn("[onDestroy] runBlocking complete — tearDownCore finished in ${elapsed}ms")
                    }
                }
            } catch (t: Throwable) {
                // tearDownCore threw a non-timeout exception before reaching its own
                // tearDownTun() (e.g. an unhandled throw between engineMutex acquisition
                // and line tearDownTun()). Without the finally below the tun fd would
                // leak — VpnService stays up, routes 0.0.0.0/0 into a dead Go core, and
                // every connection black-holes. Stopping → Error is the legal terminal
                // transition for a teardown failure (runtime_invariants.md §3.2 / §3.5).
                VeerLog.vpn(
                    "[onDestroy] tearDownCore threw ${t.javaClass.simpleName}: ${t.message}" +
                        " — forcing tun teardown",
                    VeerLog.Level.ERROR,
                )
                MihomoEngine.setState(EngineState.Error(t.message ?: "teardown failed"))
            } finally {
                // GUARANTEE the tun fd is released regardless of how tearDownCore exited
                // (normal / Layer-1 timeout / exception). Idempotent: a no-op when
                // tearDownCore already closed it (tunInterface == null), so the happy-path
                // teardown ordering (Veercore.stop() THEN tearDownTun()) is preserved.
                tearDownTun()
            }

            VeerLog.vpn("[onDestroy] cancelling serviceScope")
            serviceScope.cancel()
            super.onDestroy()
            VeerLog.vpn("[onDestroy] super.onDestroy() returned — service fully destroyed")
        } finally {
            // Guarantee the companion reference is cleared even when tearDownCore()
            // never ran (Layer 1 timeout path: withTimeoutOrNull fires before the
            // mutex is acquired). The lambda captures this@VeerVpnService; without
            // this null, the service instance would be GC-rooted via the companion
            // until the next bootCore() overwrites it.
            debugAllNetworksLostCallback = null
            val restartReplacementService =
                restartAfterDestructionRequested.getAndSet(false) &&
                    CoreRunStateStore.isDesiredRunning(applicationContext)
            if (restartReplacementService) {
                VeerLog.vpn("[onDestroy] dispatching queued start to replacement service")
                runCatching {
                    ContextCompat.startForegroundService(
                        applicationContext,
                        startIntent(applicationContext),
                    )
                }.onFailure {
                    VeerLog.vpn(
                        "[onDestroy] replacement service start failed: ${it.message}",
                        VeerLog.Level.ERROR,
                    )
                    MihomoEngine.setState(
                        EngineState.Error(it.message ?: "replacement service start failed"),
                    )
                }
            }
        }
    }

    override fun onRevoke() {
        requestShutdown("VPN revoked by system")
    }

    private fun tearDownTun() {
        val hadTun = tunInterface != null
        VeerLog.vpn("[tearDownTun] begin hadTun=$hadTun")
        runCatching { setUnderlyingNetworks(null) }
            .onFailure { VeerLog.vpn("[tearDownTun] setUnderlyingNetworks(null) threw: ${it.message}", VeerLog.Level.WARN) }
        runCatching { tunInterface?.close() }
            .onSuccess { VeerLog.vpn("[tearDownTun] tun fd closed") }
            .onFailure { VeerLog.vpn("[tearDownTun] tun close error: ${it.message}", VeerLog.Level.WARN) }
        tunInterface = null
        VeerLog.vpn("[tearDownTun] done")
    }

    // ----- Foreground notification --------------------------------------------

    private fun ensureNotificationChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.vpn_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.vpn_notification_channel_description)
                setShowBadge(false)
            }
        )
    }

    private fun startForegroundImmediately() {
        val tap = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.vpn_notification_connected))
            .setOngoing(true)
            .setContentIntent(tap)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private val effectiveWatchdogInitialDelayMs: Long
        get() = testWatchdogInitialDelayMs.takeIf { it > 0L } ?: WATCHDOG_INITIAL_DELAY_MS
    private val effectiveWatchdogIntervalMs: Long
        get() = testWatchdogIntervalMs.takeIf { it > 0L } ?: WATCHDOG_INTERVAL_MS
    private val effectiveStopTimeoutMs: Long
        get() = testStopTimeoutMs.takeIf { it > 0L } ?: STOP_TIMEOUT_MS
    private val effectiveAutoRecoveryInitialDelayMs: Long
        get() = testAutoRecoveryInitialDelayMs.takeIf { it > 0L }
            ?: AUTO_RECOVERY_INITIAL_DELAY_MS
    private val effectiveAutoRecoveryIntervalMs: Long
        get() = testAutoRecoveryIntervalMs.takeIf { it > 0L }
            ?: AUTO_RECOVERY_INTERVAL_MS
    private val effectiveAutoRecoveryFailureThreshold: Int
        get() = testAutoRecoveryFailureThreshold.takeIf { it > 0 }
            ?: AUTO_RECOVERY_FAILURE_THRESHOLD
    private val effectiveAutoRecoveryMaxCandidates: Int
        get() = testAutoRecoveryMaxCandidates.takeIf { it > 0 }
            ?: AUTO_RECOVERY_MAX_CANDIDATES

    private enum class StartDisposition {
        START_NOW,
        WAIT_FOR_DRAIN,
        WAIT_FOR_REPLACEMENT,
    }

    companion object {
        const val ACTION_START = "com.yamax.veer.action.START"
        const val ACTION_STOP  = "com.yamax.veer.action.STOP"
        private const val ACTION_RECONNECT = "com.yamax.veer.action.RECONNECT"
        private const val ACTION_PREPARE_PROFILE_SWITCH =
            "com.yamax.veer.action.PREPARE_PROFILE_SWITCH"

        private const val CHANNEL_ID       = "veer_vpn"
        private const val NOTIFICATION_ID  = 1001

        private const val VPN_MTU          = 9000
        private const val VPN_ADDRESS_V4   = "172.19.0.1"
        private const val VPN_ADDRESS_V6   = "fdfe:dcba:9876::1"
        private const val FAKE_IP_DNS      = "198.18.0.2"

        // When true, RFC1918 (LAN) traffic bypasses the tunnel and is left on the
        // underlying network. Compile-time const for now; wire to a user setting later.
        private const val BYPASS_LAN = true

        private const val WATCHDOG_INITIAL_DELAY_MS = 15_000L
        private const val WATCHDOG_INTERVAL_MS      = 30_000L
        private const val WATCHDOG_FAILURE_THRESHOLD = 3
        private const val AUTO_RECOVERY_INITIAL_DELAY_MS = 30_000L
        private const val AUTO_RECOVERY_INTERVAL_MS = 30_000L
        private const val AUTO_RECOVERY_FAILURE_THRESHOLD = 2
        private const val AUTO_RECOVERY_MAX_CANDIDATES = 3
        private const val SHUTDOWN_DESTROY_GRACE_MS = 1_000L
        // State crosses a Binder/ContentObserver boundary. Keep actionable
        // failures visible long enough for a busy main process to consume the
        // typed status before Stopping replaces it.
        private const val ERROR_VISIBILITY_MS = 1_000L
        private const val READINESS_MAX_ATTEMPTS = 10
        private const val READINESS_RETRY_DELAY_MS = 100L

        // Outer timeout: how long onDestroy waits for engineMutex (coroutine suspension — real timeout).
        private const val STOP_TIMEOUT_MS           = 4_000L
        // Inner timeout: timed Future.get on the stable native daemon executor.
        private const val STOP_JNI_TIMEOUT_MS       = 5_000L

        @JvmField @Volatile internal var testWatchdogInitialDelayMs: Long = -1L
        @JvmField @Volatile internal var testWatchdogIntervalMs: Long     = -1L
        @JvmField @Volatile internal var testStopTimeoutMs: Long          = -1L
        @JvmField @Volatile internal var testAutoRecoveryInitialDelayMs: Long = -1L
        @JvmField @Volatile internal var testAutoRecoveryIntervalMs: Long = -1L
        @JvmField @Volatile internal var testAutoRecoveryFailureThreshold: Int = -1
        @JvmField @Volatile internal var testAutoRecoveryMaxCandidates: Int = -1
        @Volatile internal var testAutoRecoveryInternetProbe: (() -> Boolean)? = null
        @Volatile internal var testAutoRecoveryExhaustedCallback: (() -> Unit)? = null
        @Volatile internal var testBeforeConnectivityMonitorStop: (() -> Unit)? = null

        // Written by bootCore() (main source set) — cannot be moved to the debug
        // source set because a debug-only declaration cannot be referenced from
        // main source set code. Internal visibility restricts it to this module;
        // the only caller outside main code is FaultInjector (debug source set).
        // Nulled in tearDownCore() and unconditionally in onDestroy() finally block.
        @Volatile internal var debugAllNetworksLostCallback: (() -> Unit)? = null

        fun startIntent(context: Context): Intent {
            CoreRunStateStore.setDesiredRunning(context, true)
            CoreStateClient.onDesiredRunningRequested()
            return Intent(context, VeerVpnService::class.java).setAction(ACTION_START)
        }

        fun stopIntent(context: Context): Intent {
            CoreRunStateStore.setDesiredRunning(context, false)
            return Intent(context, VeerVpnService::class.java).setAction(ACTION_STOP)
        }

        fun reconnectIntent(context: Context): Intent {
            CoreRunStateStore.setDesiredRunning(context, true)
            CoreStateClient.onDesiredRunningRequested()
            return Intent(context, VeerVpnService::class.java).setAction(ACTION_RECONNECT)
        }

        fun prepareProfileSwitchIntent(context: Context): Intent {
            CoreRunStateStore.setDesiredRunning(context, true)
            CoreStateClient.onDesiredRunningRequested()
            return Intent(context, VeerVpnService::class.java).setAction(ACTION_PREPARE_PROFILE_SWITCH)
        }
    }
}
