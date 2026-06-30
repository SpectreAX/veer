package com.yamax.veer.core_mihomo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import com.yamax.veer.MainActivity
import com.yamax.veer.R
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.data.ConfigManager
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import veercore.SocketProtector
import veercore.Veercore
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.net.InetAddress
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Sole owner of:
 *   • the tun ParcelFileDescriptor,
 *   • the Mihomo Go runtime's lifetime,
 *   • the foreground service notification.
 *
 * ## Architectural invariants (Phase 1.1 hardening)
 *
 * 1. `Veercore.start(...)` is called ONLY from [bootCore], which runs inside
 *    [serviceScope] and is reachable only when ACTION_START fires.
 * 2. `Veercore.stop()` is called ONLY from [tearDownCore], which is invoked
 *    from [onDestroy] via runBlocking with a 6-second timeout. This includes
 *    the case where `Veercore.start()` returned an error: [startAttempted]
 *    tracks that a start was attempted so partial Mihomo goroutines are cleaned
 *    up even when [coreRunning] was never set to true (native_runtime_contract §9).
 * 3. The tun fd never leaves this class — no public getters, no callbacks that
 *    expose it.
 * 4. [startForegroundImmediately] runs as the FIRST action in [onStartCommand]
 *    for both START and STOP intents, preventing the 5-second FGS deadline on
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
 * 2. **[STOP_JNI_TIMEOUT_MS] (inner, CountDownLatch)** — bounds the JNI call itself
 *    once [tearDownCore] is inside the mutex. `Veercore.stop()` runs on a dedicated
 *    daemon thread; [CountDownLatch.await] provides a real platform timeout that fires
 *    even with a blocking JNI frame (unlike [withTimeoutOrNull]). If this latch times
 *    out the thread is orphaned and the service transitions to [EngineState.Error] (not
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
    }
    private val serviceScope = CoroutineScope(serviceJob + Dispatchers.IO + exceptionHandler)

    private val engineMutex = Mutex()

    @Volatile private var tunInterface: ParcelFileDescriptor? = null
    @Volatile private var coreRunning: Boolean = false

    // Set to true immediately before Veercore.start() so tearDownCore() calls
    // Veercore.stop() even when start() returned an error (partial Mihomo init).
    // Reset to false inside tearDownCore() after stop() completes.
    @Volatile private var startAttempted: Boolean = false

    private var connectivityMonitor: ConnectivityMonitor? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundImmediately()

        when (intent?.action) {
            ACTION_STOP -> {
                VeerLog.vpn("[stop] ACTION_STOP received — calling stopSelf()")
                stopSelf()
                return START_NOT_STICKY
            }
            else -> serviceScope.launch { bootCore() }
        }
        return START_STICKY
    }

    // ----- Core boot ----------------------------------------------------------

    private suspend fun bootCore() {
        engineMutex.withLock {
            if (coreRunning) {
                VeerLog.vpn("[bootCore] ignored — already running")
                return
            }
            MihomoEngine.setState(EngineState.Starting)

            runCatching { Veercore.setLogger(VeerLogger()) }
                .onFailure { VeerLog.vpn("[bootCore] setLogger failed: ${it.message}", VeerLog.Level.WARN) }

            // Install socket protector before any network activity. Harmless before
            // TUN is established (protect() has no effect when there is no VPN tunnel);
            // must be set before Veercore.start() so the Go runtime's own sockets are
            // protected from the moment the tunnel comes up.
            runCatching {
                Veercore.setProtector(object : SocketProtector {
                    override fun protect(fd: Int): Boolean = this@VeerVpnService.protect(fd)
                })
                VeerLog.vpn("[bootCore] socket protector installed")
            }.onFailure {
                VeerLog.vpn("[bootCore] setProtector failed: ${it.message}", VeerLog.Level.WARN)
            }

            val homeDir = runCatching { ConfigManager.prepare(applicationContext) }
                .getOrElse { t ->
                    VeerLog.vpn("[bootCore] ConfigManager.prepare failed: ${t.message}", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error(t.message ?: "config prepare failed"))
                    // TUN not yet established — no tearDownTun() needed.
                    stopSelf()
                    return
                }

            VeerLog.vpn("[bootCore] home=${homeDir.absolutePath}")
            VeerLog.vpn("[bootCore] veer-core ${runCatching { Veercore.version() }.getOrDefault("?")}")

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
            VeerLog.vpn("[bootCore] phase=ENSURE_GEO_DB")
            val geoDbReady = GeoDatabaseManager.ensureGeoDb(applicationContext, homeDir)
            if (!geoDbReady) {
                VeerLog.vpn(
                    "[bootCore] geoip.metadb unavailable — VALIDATE_CONFIG will likely fail on GEOIP rules",
                    VeerLog.Level.WARN,
                )
            }

            // Validate config BEFORE establishing TUN. Uses reflection so the app
            // compiles against the old AAR; after rebuilding with veer-core/0.1.2+
            // the method is resolved and validation runs normally.
            val validateT0 = System.currentTimeMillis()
            VeerLog.vpn("[bootCore] phase=VALIDATE_CONFIG")
            try {
                Veercore::class.java
                    .getMethod("validateConfig", String::class.java, String::class.java)
                    .invoke(null, homeDir.absolutePath, ConfigManager.BASE_CONFIG)
                VeerLog.vpn("[bootCore] VALIDATE_CONFIG OK (+${System.currentTimeMillis() - validateT0}ms)")
            } catch (e: NoSuchMethodException) {
                VeerLog.vpn("[bootCore] VALIDATE_CONFIG skipped — rebuild AAR to enable (${e.message})")
            } catch (e: InvocationTargetException) {
                val msg = e.cause?.message ?: e.message ?: "config validation failed"
                VeerLog.vpn("[bootCore] VALIDATE_CONFIG FAILED (+${System.currentTimeMillis() - validateT0}ms): $msg", VeerLog.Level.ERROR)
                MihomoEngine.setState(EngineState.Error("Config invalid: $msg"))
                // TUN not yet established — no tearDownTun() needed.
                stopSelf()
                return
            }

            // Establish TUN only AFTER config validation succeeds. Any failure above
            // this point exits cleanly with no residual TUN interface.
            VeerLog.vpn("[bootCore] phase=ESTABLISH_TUN")
            val builder = Builder()
                .setSession("Veer")
                .setMtu(VPN_MTU)
                .addAddress(VPN_ADDRESS_V4, 30)
                .addAddress(VPN_ADDRESS_V6, 126)
                .addDnsServer(FAKE_IP_DNS)
                .setBlocking(false)

            applyRoutes(builder)
            applyAntiLoopback(builder)

            // Tell Android this VPN is not metered — prevents apps from entering
            // low-data mode (DataSaver) just because a VPN is active. CMFA also sets this.
            // minSdk is 29 (== Q) so this is always taken; the guard is kept for clarity
            // and to stay correct if minSdk is ever lowered.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

            val pfd = builder.establish()
                ?: run {
                    VeerLog.vpn("[bootCore] tun establish() returned null", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error("tun establish failed"))
                    stopSelf()
                    return
                }
            tunInterface = pfd
            VeerLog.vpn("[bootCore] ESTABLISH_TUN OK fd=${pfd.fd}")

            // startAttempted must be set BEFORE the call so that if the JNI
            // call panics and the panic recovery returns an error, tearDownCore
            // still calls Veercore.stop() to clean up any partially-initialized
            // Mihomo goroutines. See native_runtime_contract.md §9 (V1 fix).
            val startT0 = System.currentTimeMillis()
            VeerLog.vpn("[bootCore] phase=START_RUNTIME")
            startAttempted = true
            runCatching { Veercore.start(homeDir.absolutePath, ConfigManager.BASE_CONFIG, pfd.fd) }
                .onFailure { t ->
                    val msg = t.cause?.message ?: t.message ?: t.toString()
                    VeerLog.vpn("[bootCore] START_RUNTIME FAILED (+${System.currentTimeMillis() - startT0}ms): $msg", VeerLog.Level.ERROR)
                    MihomoEngine.setState(EngineState.Error(msg))
                    tearDownTun()
                    stopSelf()
                    return
                }
            VeerLog.vpn("[bootCore] START_RUNTIME OK (+${System.currentTimeMillis() - startT0}ms)")

            coreRunning = true
            VeerLog.vpn("[bootCore] mihomo core started")
            MihomoEngine.setState(EngineState.Running)
            launchWatchdog()
            val allNetworksLostHandler: () -> Unit = {
                AppStateRepository.updateConnectivity(0, false)
                VeerLog.connectivity("onAllNetworksLost coreRunning=$coreRunning")
                if (coreRunning) {
                    VeerLog.connectivity("all networks lost — signalling stop via stopSelf()")
                    MihomoEngine.setState(EngineState.Error("no network connectivity"))
                    stopSelf()
                } else {
                    VeerLog.connectivity("onAllNetworksLost ignored — teardown in progress")
                }
            }
            debugAllNetworksLostCallback = allNetworksLostHandler
            connectivityMonitor = ConnectivityMonitor(
                context = this,
                onUnderlyingNetworksChanged = { networks ->
                    setUnderlyingNetworks(networks)
                    AppStateRepository.updateConnectivity(networks.size, true)
                },
                onAllNetworksLost = allNetworksLostHandler,
            ).also { it.start() }
        }
    }

    // ----- TUN routing --------------------------------------------------------

    /**
     * Installs the tun routing table, optionally bypassing LAN (RFC1918) traffic.
     *
     * IPv6 always gets the full `::/0` default route — RFC1918 is an IPv4-only
     * concept, so LAN bypass does not apply to IPv6.
     *
     * IPv4 has two implementations gated on [Build.VERSION.SDK_INT] because
     * [VpnService.Builder.excludeRoute] is API 33 (TIRAMISU):
     *
     * - **API 33+**: install the `0.0.0.0/0` default route, then call
     *   `excludeRoute()` once per RFC1918 block ([RFC1918_BLOCKS]). The kernel
     *   keeps the LAN ranges on the underlying interface.
     * - **API 29–32**: `excludeRoute()` does not exist. Install the explicit
     *   complement of RFC1918 instead ([IPV4_BYPASS_LAN_ROUTES]) — 31 CIDR blocks
     *   that together cover the whole IPv4 space *except* 10.0.0.0/8,
     *   172.16.0.0/12 and 192.168.0.0/16. The excluded ranges are simply never
     *   routed into the tun, so they fall through to the system route table.
     *
     * When [BYPASS_LAN] is false this collapses to a plain `0.0.0.0/0` default route.
     */
    private fun applyRoutes(builder: Builder) {
        builder.addRoute("::", 0)

        if (!BYPASS_LAN) {
            builder.addRoute("0.0.0.0", 0)
            VeerLog.vpn("[bootCore] routes: 0.0.0.0/0 + ::/0 (bypassLan=off)")
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            builder.addRoute("0.0.0.0", 0)
            for ((addr, prefix) in RFC1918_BLOCKS) {
                builder.excludeRoute(IpPrefix(InetAddress.getByName(addr), prefix))
            }
            VeerLog.vpn("[bootCore] routes: 0.0.0.0/0 + ::/0, excludeRoute ${RFC1918_BLOCKS.size} RFC1918 blocks (API ${Build.VERSION.SDK_INT})")
        } else {
            for ((addr, prefix) in IPV4_BYPASS_LAN_ROUTES) {
                builder.addRoute(addr, prefix)
            }
            VeerLog.vpn("[bootCore] routes: ::/0 + ${IPV4_BYPASS_LAN_ROUTES.size} split IPv4 routes (RFC1918 bypass, API ${Build.VERSION.SDK_INT} fallback)")
        }
    }

    /**
     * Excludes Veer's own package from the tunnel so this process's own sockets
     * (the AI/DeepSeek API client, subscription HTTP fetches, and any traffic
     * Mihomo emits in-process) bypass the tun and cannot form a routing loop
     * back into the engine. `addDisallowedApplication` is API 21, safe on
     * minSdk 29. It only throws [android.content.pm.PackageManager.NameNotFoundException]
     * for an unknown package — our own package always resolves — but it is wrapped
     * defensively so a routing-config hiccup can never abort tun establishment.
     */
    private fun applyAntiLoopback(builder: Builder) {
        runCatching { builder.addDisallowedApplication(packageName) }
            .onSuccess { VeerLog.vpn("[bootCore] disallowed own package from tun: $packageName") }
            .onFailure { VeerLog.vpn("[bootCore] addDisallowedApplication($packageName) failed: ${it.message}", VeerLog.Level.WARN) }
    }

    // ----- Watchdog -----------------------------------------------------------

    /**
     * Polls the Mihomo REST API every [WATCHDOG_INTERVAL_MS]. A null response
     * means the process-internal HTTP server has gone away, which indicates a
     * Go runtime crash or hang. On detection the service transitions to Error
     * and calls [stopSelf] so [onDestroy] can attempt a clean shutdown.
     */
    private fun launchWatchdog() {
        serviceScope.launch {
            delay(effectiveWatchdogInitialDelayMs)
            while (isActive && coreRunning) {
                val version = runCatching { MihomoRepository.get().version() }.getOrNull()
                if (version == null && coreRunning) {
                    VeerLog.watchdog("Mihomo API unreachable coreRunning=$coreRunning — calling stopSelf()", VeerLog.Level.WARN)
                    MihomoEngine.setState(EngineState.Error("watchdog: core API unreachable"))
                    stopSelf()
                    break
                }
                delay(effectiveWatchdogIntervalMs)
            }
            VeerLog.watchdog("loop exited isActive=$isActive coreRunning=$coreRunning")
        }
    }

    // ----- Teardown -----------------------------------------------------------

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
     * - Normal completion → [EngineState.Stopped].
     * - JNI timeout ([STOP_JNI_TIMEOUT_MS] fires before Veercore.stop() returns) →
     *   [EngineState.Error]. The daemon thread remains orphaned; the Go runtime may
     *   still be executing executor.Shutdown(). A subsequent Veercore.start() in this
     *   process risks Mihomo global executor split-brain (Scenario 8,
     *   runtime_nonrecoverable_states.md). Error state prevents the UI from offering
     *   a seamless reconnect; the user must force-stop and reopen the app.
     *   (Stopping → Error is the documented legal transition for this failure path —
     *   see runtime_invariants.md §3.2.)
     */
    private suspend fun tearDownCore() {
        val t0 = System.currentTimeMillis()
        fun elapsed() = System.currentTimeMillis() - t0

        VeerLog.vpn("[tearDownCore] waiting for engineMutex (coreRunning=$coreRunning startAttempted=$startAttempted)")
        engineMutex.withLock {
            VeerLog.vpn("[tearDownCore] engineMutex acquired (+${elapsed()}ms)")

            // Clear coreRunning BEFORE stopping the connectivity monitor so that any
            // in-flight onAllNetworksLost / onAvailable callback that arrives on a Binder
            // thread after unregisterNetworkCallback() returns sees coreRunning=false and
            // takes the "teardown in progress" branch instead of calling
            // setState(Error)+stopSelf() during an already-in-progress onDestroy.
            val needsStop = coreRunning || startAttempted
            coreRunning = false

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

            var stopTimedOut = false
            if (needsStop) {
                // Run Veercore.stop() on a daemon thread so its JNI frame cannot
                // block the calling thread indefinitely. CountDownLatch.await() is a
                // real platform timeout (unlike Kotlin withTimeoutOrNull which is
                // ineffective once a JNI frame holds the thread).
                val stopT0 = System.currentTimeMillis()
                val latch   = CountDownLatch(1)
                VeerLog.vpn("[tearDownCore] launching Veercore.stop() on daemon thread (jniTimeout=${STOP_JNI_TIMEOUT_MS}ms)")
                Thread({
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
                    latch.countDown()
                }, "veercore-stop").apply { isDaemon = true; start() }

                VeerLog.vpn("[tearDownCore] step=latch.await(${STOP_JNI_TIMEOUT_MS}ms)")
                val jniCompleted = latch.await(STOP_JNI_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                VeerLog.vpn("[tearDownCore] step=latch.await returned completed=$jniCompleted")
                if (!jniCompleted) {
                    stopTimedOut = true
                    // The daemon thread is now orphaned. Per runtime_nonrecoverable_states.md
                    // Scenario 8 + operational recommendation: any subsequent Veercore.start()
                    // in this process risks split-brain between the orphaned executor.Shutdown()
                    // goroutine and a new executor.ApplyConfig() call. The service must
                    // transition to Error (not Stopped) so the user is not offered a seamless
                    // reconnect. The user must force-stop and reopen the app (process restart).
                    VeerLog.vpn(
                        "[tearDownCore] Veercore.stop() timed out after ${STOP_JNI_TIMEOUT_MS}ms" +
                            " — daemon thread orphaned; Go executor.Shutdown() goroutine may still be" +
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
            runCatching { Veercore.setLogger(null) }
                .onFailure { VeerLog.vpn("[tearDownCore] setLogger(null) threw: ${it.message}", VeerLog.Level.WARN) }

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
            VeerLog.vpn("[tearDownCore] step=setState(${if (stopTimedOut) "Error" else "Stopped"})")
            if (stopTimedOut) {
                MihomoEngine.setState(EngineState.Error("VPN stop timed out — restart the app to reconnect"))
            } else {
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
            VeerLog.vpn("[onDestroy] step=setState(Stopping)")
            MihomoEngine.setState(EngineState.Stopping)

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
        }
    }

    override fun onRevoke() {
        VeerLog.vpn("[stop] VPN revoked by system — calling stopSelf()")
        stopSelf()
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
            NotificationChannel(CHANNEL_ID, "Veer VPN", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Indicates that Veer is tunneling traffic."
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
            .setContentTitle("Veer")
            .setContentText("Tunneling traffic via Mihomo")
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

    companion object {
        const val ACTION_START = "com.yamax.veer.action.START"
        const val ACTION_STOP  = "com.yamax.veer.action.STOP"

        private const val CHANNEL_ID       = "veer_vpn"
        private const val NOTIFICATION_ID  = 1001

        private const val VPN_MTU          = 9000
        private const val VPN_ADDRESS_V4   = "172.19.0.1"
        private const val VPN_ADDRESS_V6   = "fdfe:dcba:9876::1"
        private const val FAKE_IP_DNS      = "198.18.0.2"

        // When true, RFC1918 (LAN) traffic bypasses the tunnel and is left on the
        // underlying network. Compile-time const for now; wire to a user setting later.
        private const val BYPASS_LAN = true

        // The three RFC1918 private-IPv4 ranges, as (address, prefixLength).
        // Used with excludeRoute() on API 33+ (each becomes an IpPrefix).
        private val RFC1918_BLOCKS: List<Pair<String, Int>> = listOf(
            "10.0.0.0" to 8,
            "172.16.0.0" to 12,
            "192.168.0.0" to 16,
        )

        // API 29–32 fallback for excludeRoute(). The exact CIDR complement of the
        // three RFC1918 blocks: every (address, prefixLength) here is routed into the
        // tun, and together they cover the whole IPv4 space EXCEPT 10.0.0.0/8,
        // 172.16.0.0/12 and 192.168.0.0/16, which are therefore left on the LAN.
        // Computed as the gaps around the three excluded ranges; do not edit by hand
        // without recomputing the complement.
        private val IPV4_BYPASS_LAN_ROUTES: List<Pair<String, Int>> = listOf(
            // 0.0.0.0 – 9.255.255.255  (before 10.0.0.0/8)
            "0.0.0.0" to 5,
            "8.0.0.0" to 7,
            // 11.0.0.0 – 172.15.255.255  (between 10/8 and 172.16/12)
            "11.0.0.0" to 8,
            "12.0.0.0" to 6,
            "16.0.0.0" to 4,
            "32.0.0.0" to 3,
            "64.0.0.0" to 2,
            "128.0.0.0" to 3,
            "160.0.0.0" to 5,
            "168.0.0.0" to 6,
            "172.0.0.0" to 12,
            // 172.32.0.0 – 192.167.255.255  (between 172.16/12 and 192.168/16)
            "172.32.0.0" to 11,
            "172.64.0.0" to 10,
            "172.128.0.0" to 9,
            "173.0.0.0" to 8,
            "174.0.0.0" to 7,
            "176.0.0.0" to 4,
            "192.0.0.0" to 9,
            "192.128.0.0" to 11,
            "192.160.0.0" to 13,
            // 192.169.0.0 – 255.255.255.255  (after 192.168/16)
            "192.169.0.0" to 16,
            "192.170.0.0" to 15,
            "192.172.0.0" to 14,
            "192.176.0.0" to 12,
            "192.192.0.0" to 10,
            "193.0.0.0" to 8,
            "194.0.0.0" to 7,
            "196.0.0.0" to 6,
            "200.0.0.0" to 5,
            "208.0.0.0" to 4,
            "224.0.0.0" to 3,
        )

        private const val WATCHDOG_INITIAL_DELAY_MS = 15_000L
        private const val WATCHDOG_INTERVAL_MS      = 30_000L

        // Outer timeout: how long onDestroy waits for engineMutex (coroutine suspension — real timeout).
        private const val STOP_TIMEOUT_MS           = 4_000L
        // Inner timeout: how long we wait for Veercore.stop() on its daemon thread (CountDownLatch — real timeout).
        private const val STOP_JNI_TIMEOUT_MS       = 5_000L

        @JvmField @Volatile internal var testWatchdogInitialDelayMs: Long = -1L
        @JvmField @Volatile internal var testWatchdogIntervalMs: Long     = -1L
        @JvmField @Volatile internal var testStopTimeoutMs: Long          = -1L

        // Written by bootCore() (main source set) — cannot be moved to the debug
        // source set because a debug-only declaration cannot be referenced from
        // main source set code. Internal visibility restricts it to this module;
        // the only caller outside main code is FaultInjector (debug source set).
        // Nulled in tearDownCore() and unconditionally in onDestroy() finally block.
        @Volatile internal var debugAllNetworksLostCallback: (() -> Unit)? = null

        fun startIntent(context: Context): Intent =
            Intent(context, VeerVpnService::class.java).setAction(ACTION_START)

        fun stopIntent(context: Context): Intent =
            Intent(context, VeerVpnService::class.java).setAction(ACTION_STOP)
    }
}
