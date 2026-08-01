# Veer Process Isolation Architecture: Analysis and Implementation

## Implemented topology (2026-07-29)

Process isolation is now implemented. The architecture comparison below is
retained as the decision record; references to “current in-process
architecture” describe the pre-migration state.

The selected topology is A2 Option 2a:

```text
com.yamax.veer (UI)                  com.yamax.veer:veercore
────────────────────────            ─────────────────────────────
Compose activities                  VeerVpnService
AI/profile/rule UI                  Android-owned TUN
CoreStateClient          IPC        SocketProtector / protect(fd)
UI-side StateFlow mirror  ◄──────►  MihomoEngine + ConnectivityMonitor
                                      │
                                      └─ gomobile Veercore / Mihomo
```

Key implementation decisions:

- `VeerVpnService`, TUN ownership, `protect(fd)` and all Go runtime lifecycle
  calls live in `:veercore`. No TUN fd transfer and no per-socket Binder call
  is required.
- Start, stop, reconnect and profile-switch preparation remain explicit
  service intents. The user’s desired running state is stored in a
  cross-process file marker rather than incoherent multi-process
  `SharedPreferences`.
- A non-exported, same-UID `ContentProvider` is the bounded IPC surface for
  engine/startup/connectivity state, traffic counters, route summary, log
  snapshots and rule hot reload.
- Runtime state changes call `notifyChange`; the UI mirrors them into its
  process-local `StateFlow`. High-frequency traffic uses a single bounded IPC
  call and never transfers the full proxy tree.
- Rule reload validates that the requested file remains below app-private
  storage, then executes `Veercore.reloadRules` in `:veercore`. This prevents a
  second, accidental Go runtime from being addressed in the UI process.
- UI process death does not affect the VPN. If an observed Running core PID is
  replaced unexpectedly while the user still expects a connection, the main
  process restarts the VPN service once for the replacement PID. Explicit stop
  clears the marker first and is never auto-recovered.
- Core log IPC is capped at 200 lines and 800 characters per line and is polled
  only while the diagnostic panel is expanded and the Activity is resumed.
- Debug fault injection and goroutine inventory have a separate debug-only
  provider hosted in `:veercore`, so instrumentation mutates the runtime under
  test rather than the UI process.

Runtime acceptance on the Android 16 arm64 emulator:

- UI PID death: core PID unchanged; controller 200 and proxied HTTPS 204;
  relaunched UI synchronized to Running.
- Core PID death: replacement PID launched and real proxy traffic recovered in
  about 7 seconds.
- Explicit stop: remained Stopped for the observation window; no false
  auto-restart.
- Fast reconnect: same core PID, real proxy traffic recovered in about
  1.55 seconds.
- The final device suite passed all 16 instrumentation tests, including
  cross-process startup-error cleanup, native startup-stage mirroring, fast
  reconnect, a delayed connectivity callback during shutdown, and the Compose
  startup-progress contract.

Measured results and raw artifact paths are recorded in
`PERFORMANCE_BASELINE_2026-07-29.md`.

**Scope:** Evaluates whether Veercore should remain in-process with the Android application or
move to a separate process. Compares five architectural options across twelve dimensions. Concludes
with a recovery-class analysis and a recommendation for Phase 2 migration priority.

**Prerequisite reading:**
- `native_runtime_contract.md` — JNI boundary constraints and audit findings
- `runtime_nonrecoverable_states.md` — failure classification (Scenarios 1–8, Flaws F1–F4)
- `runtime_lifecycle_proposal.md` — cooperative Runtime struct design

---

## Foundational Constraints

Three Android-platform facts constrain every architectural option. They are stated here so each
approach section can reference them without re-derivation.

### C1 — VpnService ownership is process-bound

`VpnService.establish()` returns a `ParcelFileDescriptor` that is owned by the process hosting
the `VpnService` subclass. Only that process can call `VpnService.protect(fd)` to exempt a
socket from the VPN's routing table. There is no API to delegate VPN ownership to another
process or to call `protect()` on behalf of a different process.

Consequence: any architecture that runs Mihomo outside the VpnService process must solve the
socket-protection problem — Mihomo creates outbound sockets for every proxy connection and DNS
query, and each must be exempted from the tun or a routing loop results.

### C2 — Go goroutines are immortal within their process

A goroutine blocked in a kernel syscall or JNI call cannot be interrupted or killed by any
Go-language mechanism. The only way to reclaim a stuck goroutine is process death. This is the
primary argument for process isolation. Any architecture where Mihomo goroutines share a process
with Android UI state cannot guarantee clean recovery from a hung `ApplyConfig` or `Shutdown`.

### C3 — Mihomo executor uses global process state

`executor.ApplyConfig` and `executor.Shutdown` operate on package-level globals in Mihomo's
`executor` package: the proxy tunnel factory, rule engine, DNS cache, and connection pool. Two
concurrent calls to either function in the same process are undefined behavior at the Mihomo
level regardless of how many `Runtime` struct instances exist. This means process isolation is
the only mechanism that can fully contain split-brain executor state.

---

## Architecture Overviews

### A1 — Current In-Process gomobile

Mihomo runs as a gomobile `.aar` loaded into the app's main process via `System.loadLibrary`.
`VeerVpnService`, the Mihomo Go runtime, and `MainActivity` share one address space. All calls
cross the JNI boundary but remain within a single OS process.

```
┌─────────────────────────── app process (com.yamax.veer) ───────────────────────────┐
│  MainActivity  ◄──StateFlow──  MihomoEngine  ◄──setState──  VeerVpnService         │
│                                                               │                     │
│                                                       JNI │   protect(fd)           │
│                                                           ▼                         │
│                                          Mihomo Go runtime (gomobile .aar)          │
│                                          executor.ApplyConfig / executor.Shutdown   │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### A2 — Android Isolated Process Service

`VeerVpnService` and the Mihomo runtime move to a separate Android process declared with
`android:process=":veercore"` in the manifest. The isolated process shares the same UID as the
main app (`:` prefix, not `android:sharedUserId`). The UI process communicates with it via
Binder. Socket protection is eliminated per-socket by binding the `:veercore` process to the
underlying physical network using `ConnectivityManager.bindProcessToNetwork()`.

```
┌─── app process (com.yamax.veer) ───┐   Binder AIDL    ┌─── :veercore process ─────────────┐
│  MainActivity                       │ ◄────────────►   │  VeerVpnService                    │
│  MihomoEngine (UI-side proxy)       │   state, cmds    │  EngineService (AIDL impl)         │
└─────────────────────────────────────┘                   │                │                  │
                                                          │         JNI    │                  │
                                                          │                ▼                  │
                                                          │  Mihomo Go runtime (same .aar)    │
                                                          │  bindProcessToNetwork(underlying) │
                                                          └───────────────────────────────────┘
```

### A3 — Native Daemon Subprocess

Mihomo is compiled as a standalone Go binary (not via gomobile) bundled as a native library
(`.so` renamed) extracted to `filesDir`. The main process forks and execs this binary. The
tun fd is passed to the subprocess via `SCM_RIGHTS` over a UNIX domain socket established
before exec. The Mihomo REST API (`127.0.0.1:9090`) is the control plane. Socket protection
is handled the same way as A2 (bind subprocess to underlying network) or via a per-socket
SCM_RIGHTS round-trip.

```
┌─── app process (com.yamax.veer) ──────────────────┐      ┌── mihomo daemon (native binary) ──┐
│  VeerVpnService                                    │      │  Go runtime (full, no gomobile)   │
│    └─ ProcessManager                               │      │  Mihomo executor (direct calls)   │
│         ├─ fork/exec veercore binary               │      │  REST API :9090                   │
│         ├─ SCM_RIGHTS tun fd transfer ─────────────┼─────►│                                   │
│         └─ UNIX socket control channel ─────────── ┼─────►│                                   │
│  MainActivity  ◄── HTTP MihomoRepository ──────────┼─────►│  GET /version, PUT /providers/.. │
└───────────────────────────────────────────────────-┘      └───────────────────────────────────┘
```

### A4 — Binder IPC Architecture

An explicit AIDL interface separates the Android lifecycle layer (Binder service) from the
Mihomo runtime. Can be deployed either in-process (performance) or in a separate process
(isolation). The key distinction from A2 is that A4 treats Binder as a first-class design
choice: operations are typed, versioned, and transacted through AIDL descriptors rather than
relying on `startService` intent extras and broadcast receivers. Can be combined with the
`:veercore` process or run in-process depending on isolation requirements.

```
┌── AIDL interface: IVeerCoreService ─────────────────────────────────────────────────────┐
│  void start(in ParcelFileDescriptor tunFd, in VeerConfig config);                       │
│  void stop();                                                                           │
│  EngineStateParcel getState();                                                          │
│  void registerCallback(in IVeerCoreCallback cb);   // StateFlow equivalent via Binder  │
│  void unregisterCallback(in IVeerCoreCallback cb);                                     │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         ▲ Binder proxy (UI process)          │ Binder stub (veercore process or in-process)
```

A4 is an API-boundary concern, not a topology concern. It is complementary to A2 (the
isolation mechanism). A2 without A4 relies on service intents for control, which is
fire-and-forget with no acknowledgement. A2 with A4 provides typed, acknowledged,
observable control.

### A5 — UNIX Domain Socket IPC

A UNIX domain socket (`LocalServerSocket` / `LocalSocket`) is established between the main
process and the Mihomo host (which may be a `:veercore` Android process or a native subprocess).
The socket serves two functions: (1) control plane — newline-delimited JSON commands for
start/stop/state query; (2) log forwarding — streaming log events to the main process. The
tun fd is transferred via `SCM_RIGHTS` ancillary data. Mihomo's existing REST API at `:9090`
handles all runtime configuration changes (proxy group selection, rule provider reload).

A5 is also a transport concern, not a topology concern. It pairs with A3 (native daemon) and
can augment A2 for log streaming. Evaluated here as a standalone alternative to Binder.

---

## Dimension Analysis

### D1 — Runtime Recoverability

**A1 (In-process gomobile):**
Recoverability is bounded by goroutine lifecycle (C2). Scenarios 1, 2, and 8 from
`runtime_nonrecoverable_states.md` all ultimately require process restart. Since Mihomo and
the UI share one process, process restart kills all Android back-stack, in-flight AI sessions,
and the user's view of VPN state simultaneously. The 6-second `tearDownCore` timeout prevents
ANR on the main thread, but a hung `executor.Shutdown()` still holds the IO thread past the
timeout, and the Go goroutine persists indefinitely.

Achievable recovery without process restart:
- Normal `Stop()` path (no hang): CAS + fd released, service restarts cleanly.
- Failed `Start()` with error return: `startAttempted` flag ensures cleanup; restartable.

Not achievable:
- Hung `ApplyConfig`: zombie goroutine in process, restart creates split-brain.
- Hung `Shutdown`: zombie goroutine in process, restart creates split-brain.
- Unhandled goroutine panic (7b/7c): process terminates unconditionally.

**A2 (Isolated process):**
Recovery is complete for all Scenario classes. Any failure — hung goroutine, split-brain,
deadlocked Shutdown, panic in background goroutine — can be resolved by killing the `:veercore`
process. The main process (UI) is unaffected. A new `:veercore` process starts with a clean
Go heap, no zombie goroutines, and fresh Mihomo global state. The tun fd (held in the main
process's `VeerVpnService`) is re-passed to the new process after it starts. Recovery is
bounded to the `:veercore` process startup time (~300–500ms).

**A3 (Native daemon):**
Identical isolation properties to A2. Kill the daemon PID, `waitpid` for exit (or `SIGKILL`
after timeout), restart via `exec`. The main process holds the `ParcelFileDescriptor` and
re-passes the tun fd via SCM_RIGHTS on reconnect. Slightly better recoverability than A2 for
SIGKILL semantics: `android.os.Process.killProcess()` for `:veercore` sends SIGKILL and requires
Zygote cooperation; a native `kill(pid, SIGKILL)` is a direct kernel call. However, managing
the daemon PID requires `prctl(PR_SET_PDEATHSIG, SIGKILL)` to ensure the daemon exits when its
parent is killed.

**A4 (Binder IPC):**
Recoverability depends on whether A4 is deployed in-process or with A2's process isolation.
In-process A4 has identical recoverability to A1. A4 + A2 has identical recoverability to A2.
A4's contribution is typed acknowledgement: `start()` returns a result, so the caller knows
whether the core started cleanly rather than relying on a watchdog timer.

**A5 (UNIX socket):**
Same as A4 — topology-dependent. A5 adds better log streaming architecture (no Binder
transaction overhead on high-frequency log events). Does not change recoverability properties.

---

### D2 — Goroutine Leak Containment

**A1:** Zero containment. A goroutine blocked in `executor.ApplyConfig` or spawned by Mihomo
during startup persists in the app process indefinitely. Subsequent `Runtime` instances (if the
cooperative proposal is implemented) create additional goroutines. After N failed restart
cycles, the process may have N zombie goroutines all touching Mihomo global state. The Go
runtime's goroutine scheduler continues attempting to schedule these goroutines, consuming
stack space (8 KB minimum per goroutine, growing with depth) and CPU time when they wake
from syscalls.

**A2, A3:** Complete containment. Every goroutine in the Mihomo runtime lives inside a process
boundary. `SIGKILL` on the process causes the kernel to reclaim all memory, threads, and file
descriptors. No zombie goroutine can ever outlive its process.

**A4, A5:** Same as A1 if in-process, same as A2/A3 if the transport spans a process boundary.

---

### D3 — VPN fd Ownership

**A1:** Trivial. `syscall.Dup(pfd.fd)` in `veer_core.go::Start` gives Go a private fd copy.
The tun fd never leaves the process. When the VPN closes, both `ParcelFileDescriptor.close()`
(JVM side) and `syscall.Close(r.fdDup)` (Go side, via `Cleanup()`) must be called. Both happen
within the same process address space with no IPC.

**A2:** The tun fd must cross the process boundary before Mihomo can use it.

Mechanism: `VeerVpnService` holds the `ParcelFileDescriptor`. After the `:veercore` process
starts and its Binder service is bound, `VeerVpnService` calls the AIDL `start()` method and
passes the `ParcelFileDescriptor` as a parameter. Binder automatically transfers the fd via
`sendmsg(MSG_DONTWAIT, SCM_RIGHTS)` under the hood — the receiving process gets a new fd
number pointing to the same kernel `file` struct (refcount incremented).

After transfer: the `:veercore` process's Go runtime calls `Dup` on the received fd and the
AIDL layer closes its copy. The result is the same ownership model as A1, but the tun fd's
lifecycle is now coordinated through Binder transactions.

**Lifecycle table for A2 fd:**
| Event | fd refcount action |
|---|---|
| `VeerVpnService.establish()` | refcount = 1 (Java PFD) |
| Binder `start(pfd)` call | refcount = 2 (Java PFD + veercore-received fd) |
| veercore AIDL stub receives fd, dups | refcount = 3 (Java PFD + Binder copy + Go dup) |
| Binder closes its transfer copy | refcount = 2 |
| VeerVpnService closes PFD on teardown | refcount = 1 (Go dup only) |
| Go Cleanup() closes its dup | refcount = 0, kernel closes tun |

This is correct: the tun device stays alive as long as Mihomo needs it, and is released exactly
when `Cleanup()` completes. The `sync.Once` requirement (Flaw F6) applies identically.

**A3:** Same mechanism, but via `SCM_RIGHTS` over the control UNIX socket rather than Binder.
The receiving native process must call `recvmsg` and then `dup` the received fd. This is more
brittle — the caller must implement the `cmsg_len`/`CMSG_DATA` protocol correctly, and errors
during fd receipt (e.g., the socket is closed before the fd is received) must be handled
explicitly. No framework abstracts this for you, unlike Binder's automatic `ParcelFileDescriptor`
marshalling.

**A4:** Same as A2 — Binder handles the transfer. A4 adds versioning to the `start()` AIDL
method signature, so future parameters (e.g., an fd array for multi-profile) can be added
without breaking the interface contract.

**A5:** SCM_RIGHTS, same as A3.

---

### D4 — Startup Latency

**A1 (baseline):**
- Process is already running (app is open).
- `System.loadLibrary("veer_core")` is done at app launch.
- `Veercore.start()` JNI call: 200–1500ms depending on disk cache state.
- **Total VPN start latency: 200–1500ms** (dominated by `executor.ApplyConfig`).

**A2:**
- If `:veercore` process is not running: Android must fork from Zygote (~150–300ms for the
  process start) + Go runtime initialization inside the new process (~50–100ms) + AIDL
  `start()` call with `executor.ApplyConfig` (200–1500ms).
- If `:veercore` process is already running (service not stopped): only the `ApplyConfig` phase.
- **Total for cold `:veercore` process: 500–1900ms** (~200–400ms overhead vs A1).
- Mitigation: start the `:veercore` service eagerly on app open so the process is warm by
  the time the user taps "Connect". The service stays idle (no tun, no executor) until
  the AIDL `start(pfd)` call arrives.

**A3:**
- `Runtime.exec()` or `ProcessBuilder` to start the binary: the binary must be extracted from
  APK assets/jniLibs to `filesDir` on first run, which takes ~50–200ms for a ~5–15MB binary.
  Subsequent starts use the cached binary.
- fork + exec: ~50–100ms.
- Go runtime init: ~50–100ms.
- Control socket handshake: ~10–30ms.
- `ApplyConfig`: 200–1500ms.
- **Total for cold binary: 400–2000ms.** Extraction adds one-time ~200ms on first ever start.

**A4:**
Same latency as A2 (Binder) or A3 (sockets) depending on the underlying transport.

**A5:**
UNIX socket setup has ~0.5–2ms overhead compared to Binder's ~2–5ms per transaction.
For infrequent control operations (start/stop), this difference is negligible. For high-frequency
log streaming, UNIX socket wins meaningfully.

---

### D5 — Android VpnService Constraints

**A1:**
No cross-process concerns. `VpnService.protect(fd)` is a direct method call. The `SocketProtector`
Kotlin object passed to `Veercore.setProtector()` calls `this@VeerVpnService.protect(fd)` —
same instance, no IPC.

**A2:**
The `:veercore` process runs as the same UID as the main process. `VpnService` must stay in
either the main process or the `:veercore` process — not split. Two options:

*Option 2a — VpnService in `:veercore` process:*
```xml
<service
    android:name=".core_mihomo.VeerVpnService"
    android:process=":veercore"
    android:permission="android.permission.BIND_VPN_SERVICE" />
```
The `VpnService.protect()` calls from Mihomo's `SocketProtector` remain in-process within
`:veercore`. `VeerVpnService` is in the same process as Mihomo. The main process hosts only
`MainActivity` and an AIDL `ServiceConnection` that binds to the `:veercore` service.

*Option 2b — VpnService in main process, Mihomo in `:veercore`:*
Every socket Mihomo creates requires a cross-process `protect()` call (~1–5ms via Binder).
With Mihomo making dozens of connections per second and DNS sockets per resolution, this adds
tens to hundreds of milliseconds of per-connection overhead. **This option is operationally
unacceptable without the `bindProcessToNetwork()` bypass.**

*`bindProcessToNetwork()` bypass:*
After `VpnService.establish()` returns, the main process calls
`ConnectivityManager.getActiveNetwork()` to get the underlying (pre-VPN) network. This
`Network` object is passed to the `:veercore` process (as a `Parcelable` via Binder). The
`:veercore` process calls `ConnectivityManager.bindProcessToNetwork(underlyingNetwork)`.
All sockets from that process now route through the physical network, bypassing the tun —
without any per-socket `protect()` call.

This is the recommended solution for Option 2b and is used by production Android VPN
applications (e.g., Shadowsocks-Android, OpenVPN for Android on API 23+).

Limitation: `bindProcessToNetwork()` binds the entire process. If the `:veercore` process
ever creates sockets that *should* go through the VPN (e.g., future meta-proxy features),
this becomes a problem. Option 2a avoids this entirely.

**Recommendation for A2:** Option 2a — move `VeerVpnService` with Mihomo into the same
`:veercore` process. `protect()` remains in-process. The main process has no VPN responsibility
beyond displaying state.

**A3:**
Same `bindProcessToNetwork()` or per-socket SCM_RIGHTS round-trip for protection. Option 2a
equivalent does not exist for native daemons (the daemon cannot host a `VpnService`).
Per-socket protection via the control UNIX socket is feasible but adds latency.

**Mandatory:** `prctl(PR_SET_PDEATHSIG, SIGKILL)` in the daemon process so it exits when
the app process dies. Without this, the daemon outlives the app and holds the tun fd open
after Android has already reassigned it.

**A4, A5:** Inherit the constraint from A2 or A3 depending on topology.

---

### D6 — Memory Overhead

**A1 (baseline):**
- Go runtime heap: ~15–40MB (Mihomo + rule databases + connection pool).
- Mihomo rule database (GeoIP, GeoSite): ~8–20MB if loaded.
- Total: ~25–60MB in addition to the ART heap.
- No duplication — single process.

**A2:**
- `:veercore` process requires its own ART/JVM instance: ~20–30MB baseline Android process overhead.
- Go runtime in `:veercore`: same ~15–40MB.
- Main process no longer runs Go — saves ~15–40MB there.
- Net overhead: **+20–30MB** (one extra ART process).
- On low-RAM devices (2GB), this is a meaningful cost. On modern devices (6–12GB), acceptable.

**A3:**
- Native daemon: no ART/JVM overhead (~10–15MB lighter than A2's `:veercore` process).
- Go runtime: same.
- **Net overhead: +10–15MB vs A1.**
- This is the lowest-overhead multi-process option.

**A4, A5:**
Binder/socket IPC adds negligible memory overhead (~2–4MB kernel buffer). The process model
dominates memory cost, not the IPC mechanism.

---

### D7 — Crash Isolation

**A1:**
None. An unhandled panic in any Mihomo background goroutine (e.g., a goroutine spawned by
`executor.ApplyConfig` that panics on a nil pointer in the proxy chain) terminates the Go
runtime, which terminates the entire Android process. The app disappears from the screen.
`START_STICKY` causes Android to restart `VeerVpnService` but the app process is gone — the
user loses any in-memory state.

This is not hypothetical: Mihomo's background goroutines have no `defer recover()`. The
`defer recover()` in `veer_core.go::Start` only catches panics on the calling goroutine's
stack. A panic inside a goroutine launched by `executor.ApplyConfig` propagates to the Go
runtime and terminates the process unconditionally.

**A2:**
Complete isolation. The panic in the Mihomo goroutine terminates the `:veercore` process.
The main app process (and `MainActivity`) remain alive. Android reports the `:veercore`
process death via the Binder death recipient (`linkToDeath`) registered by the main process.
The main process updates `EngineState.Error` and shows the user an error message. No app
restart required.

**A3:**
Same isolation as A2. The daemon process dies; the main process detects it via `waitpid`
or SIGCHLD. Recovery is a process restart.

**A4, A5:**
Binder's `IBinder.DeathRecipient` for A4 and EPIPE detection on the socket for A5 provide
equivalent death notification. Both give the main process immediate notification of the
Mihomo-host process dying, with no polling required.

---

### D8 — Observability

**A1:**
Maximum observability: shared memory means `MihomoEngine.publishCoreLog()` writes directly
to a `SharedFlow` in the same process. No IPC, no serialization. The UI sees log events
within microseconds. `MihomoRepository` makes HTTP calls to `127.0.0.1:9090` from the same
process. Breakpoints in `VeerLogger`, `VeerVpnService`, and `LlmClient` all work in a single
Android Studio debug session.

**A2:**
Log events from `veercore.Logger` are delivered via Binder or UNIX socket to the main process.
Binder imposes ~2–5ms per transaction plus serialization overhead. For high-frequency log
events (debug level during startup), this adds latency and may buffer events if the main
process is slow to consume. A UNIX streaming socket (A5 transport) is better for log forwarding:
events arrive in order with ~0.1–0.5ms latency and the kernel buffers them without dropping.

`MihomoRepository`'s REST calls to `127.0.0.1:9090` work identically from either process —
the loopback address is process-independent.

`EngineState` updates require an explicit callback from `:veercore` to the main process. The
AIDL `IVeerCoreCallback` interface covers this. The main process's `MihomoEngine` becomes
a Binder client that receives state updates from `:veercore` and republishes them to the UI
`StateFlow`.

**A3:**
Log forwarding is via the UNIX control socket (newline-delimited JSON) or a dedicated log
socket. Native daemon logs do not appear in Logcat automatically — you must explicitly forward
them. Logcat filtering by PID becomes necessary. `adb shell logcat --pid=<daemon-pid>` is
required to filter daemon logs.

**A4:**
AIDL typed callbacks provide structured observability events (state changes, error codes). This
is more structured than raw log streaming and easier to test. Binder transactions are
traceable via `systrace`/`perfetto` — each transaction shows up as a named slice in the
timeline, making IPC latency directly measurable.

**A5:**
UNIX socket traffic is not automatically captured by Android's observability tools. You must
add explicit logging at send/receive sites. However, UNIX socket streaming is better for
high-throughput log forwarding than Binder's per-transaction model.

---

### D9 — Debugging Complexity

**A1:**
Single process. One `adb jdwp` session, one Android Studio "Attach Debugger to Android
Process" target. Go-side debugging requires `gdbserver` or `lldb-server` attached to the
same PID. Mixed-language debugging (Kotlin breakpoint in `VeerVpnService.bootCore` +
stepping into the JNI frame) is partially supported in Android Studio's LLDB integration.

**A2:**
Two JVM processes. Android Studio's multi-process debugging supports both (`Run > Attach
Debugger to Android Process` for each). However, a Binder death causes one process to
disappear from the debugger while the other continues — this is actually *useful* for
debugging crash isolation behavior. The Binder `DeathRecipient` callback is debuggable
from the main process.

Go debugging in `:veercore`: attach `lldb-server` to the `:veercore` PID separately. The
Go runtime's goroutine state is visible via `goroutine` LLDB commands with the Go plugin.

Overall complexity: **moderately higher than A1**, but the ability to kill and restart
`:veercore` without losing the main process debug session is a concrete debugging advantage
during Mihomo integration work.

**A3:**
Native daemon is the hardest to debug. No JVM, no JDWP. Must use:
- `lldb-server` pushed to `/data/local/tmp/` and attached to the daemon PID.
- Or `gdb` via `adb shell`.
- Logcat requires explicit log forwarding.
- `strace`/`ftrace` for syscall-level tracing.

Android Studio has no integration with a native subprocess that is not loaded via `dlopen`.
**Highest debugging complexity** of all five options.

**A4:**
Adds AIDL transaction tracing on top of A2. Binder transactions appear in Perfetto with full
arguments if the service is built with `android:debuggable="true"`. This makes IPC call
chains visible in the timeline — an advantage over both A1 and A5 for diagnosing startup
latency and callback ordering.

**A5:**
UNIX socket traffic must be tapped manually (e.g., by adding logging at both ends). No system
tracing integration. For control plane debugging, this is harder than Binder. For log
streaming debugging, `tcpdump -s 65535 -A -w - -i lo | strings` can tap loopback traffic
but UNIX socket traffic does not appear on the loopback interface — a separate `strace` on
the socket file descriptor is needed.

---

### D10 — Compatibility with Mihomo Globals

**A1:**
Mihomo's global state is process-scoped. Single process = single Mihomo instance. `executor`
globals are consistent. No compatibility issues as long as the `engineMutex` invariant is
maintained (which VeerVpnService currently does).

**A2, A3:**
Each separate process has its own copy of all Mihomo globals. Two processes = two independent
Mihomo instances, each with its own `executor`, proxy tables, and DNS cache. They do not
share state at the Go level (IPC is the only inter-process communication channel). This is
exactly what multi-process requires: each process can run a different Mihomo configuration
without any global state conflict.

Within each process, Mihomo globals remain single-instance. The constraint (C3) is satisfied
within each process boundary.

**A4, A5:**
Same as A2/A3 — these are transport mechanisms and do not affect Go global state semantics.

---

### D11 — Future Multi-Profile Support

A "multi-profile" scenario means running two independent Mihomo configurations simultaneously —
e.g., a home profile and a work profile, each with different proxy groups, rule sets, and
potentially different tun configurations.

**A1:**
Impossible. Mihomo's `executor` package uses global state. Two concurrent `ApplyConfig` calls
are undefined behavior. The only way to switch profiles is `Shutdown()` + `ApplyConfig()` with
the new config — which requires VPN teardown and re-establishment, visible to the user as a
connection drop.

**A2:**
Multiple `:veercore` processes are theoretically possible (`:veercore1`, `:veercore2`), each
with an independent Mihomo instance and tun fd. However, Android only permits one active VPN
at a time (`VpnService` can only have one established tun). True simultaneous multi-profile
is blocked by Android's VPN model at the OS level.

Practical benefit: hot-swap profiles by killing `:veercore` and restarting it with a different
`homeDir`. No UI process restart required. The new `:veercore` process initializes with the
new config in parallel while the old tun is still up — atomic switch when the new tun is
established (requires Android VPN re-establish semantics, which works cleanly).

**A3:**
Same as A2 for profile switching. Daemon kill + restart with new config. Slightly faster
restart than A2 (no Zygote overhead). Same Android single-VPN limitation.

**A4:**
AIDL `start(pfd, config)` can carry the full config as a `Parcelable`. Profile switching is
a single Binder transaction. The AIDL version field allows protocol extension for future
multi-profile parameters.

**A5:**
JSON control message `{"action": "start", "config": {...}}` carries config inline. Less typed
than AIDL but requires no schema compilation step.

---

### D12 — Process Restart Semantics

**A1:**
Process restart (`android.os.Process.killProcess(Process.myPid())`) kills the entire app —
UI, AI chat history, and VPN state all disappear simultaneously. `START_STICKY` causes Android
to restart `VeerVpnService` but not necessarily the activity. From the user's perspective this
is an app crash.

**A2:**
`:veercore` process restart (`android.os.Process.killProcess(veerocorePid)` or via Binder
service kill) is transparent to the user. `MainActivity` receives a Binder death notification,
shows "Reconnecting", waits for the new `:veercore` service to bind, then re-issues `start(pfd)`.
The tun fd is briefly closed during the transition (one connection blink).

Automatic restart via `android:persistent` is inappropriate (that flag is for system services).
The recommended approach is manual restart from the main process: the Binder `DeathRecipient`
triggers `startService(Intent(":veercore class"))` followed by `bindService`.

**A3:**
`Runtime.exec()` to restart the native binary. The main process's `ProcessManager` tracks the
daemon PID via `Process.pid()` and detects death via SIGCHLD (`ProcessBuilder.redirectErrorStream`)
or `waitpid`. After death detection, `exec` the binary again and re-establish the UNIX socket
and tun fd transfer. Slightly more manual coordination than A2's automatic Binder rebind.

**A4:**
AIDL service rebind is automatic: after the service process dies, `onServiceDisconnected` fires
in the main process. Calling `bindService` again starts the new process and binds when ready.
The AIDL `IBinder` death notification is more reliable than `onServiceDisconnected` (the latter
fires for any disconnect, the former specifically for process death).

**A5:**
UNIX socket receives `EPIPE` or `ECONNRESET` on the read side when the daemon dies. The main
process interprets this as process death and restarts the daemon. More polling-oriented than
Binder's push notification model.

---

## Comparison Matrix

| Dimension | A1 In-Process | A2 Isolated Process | A3 Native Daemon | A4 Binder IPC | A5 UNIX Socket |
|---|---|---|---|---|---|
| Runtime recoverability | Poor | Excellent | Excellent | A1 or A2 | A1 or A3 |
| Goroutine leak containment | None | Complete | Complete | None / Complete | None / Complete |
| VPN fd ownership | Trivial | Binder transfer | SCM_RIGHTS | Binder (typed) | SCM_RIGHTS |
| Startup latency | 200–1500ms | +200–400ms | +200–500ms | Same as A2 | Same as A3 |
| VpnService constraints | None | Option 2a solves cleanly | `bindProcessToNetwork` required | Inherit from A2 | Inherit from A3 |
| Memory overhead (net) | Baseline | +20–30MB | +10–15MB | +1–2MB (IPC) | +1–2MB (IPC) |
| Crash isolation | None | Complete | Complete | None / Complete | None / Complete |
| Observability | Highest | High (+ IPC overhead on logs) | Medium (manual log fwd) | High (Perfetto tracing) | Medium |
| Debugging complexity | Low | Medium | High | Medium | Medium |
| Mihomo globals compat | Single-instance | Per-process | Per-process | Same as topology | Same as topology |
| Multi-profile support | Impossible | Hot-swap only | Hot-swap only | Protocol-extensible | Protocol-extensible |
| Process restart semantics | Kills UI | Transparent | Manual coord | Automatic rebind | EPIPE detection |

Note: A4 and A5 rows show their contribution as IPC transport. Their topology-dependent cells
reflect the underlying process model (A2 or A3) they are deployed with.

---

## Failure Class Analysis Under Each Architecture

### Failures impossible to recover without process restart

**Under A1 (current architecture):**

1. **Unhandled Mihomo goroutine panic (Scenario 7b/7c):** A goroutine spawned by
   `executor.ApplyConfig` panics. Go runtime terminates the process. No warning, no graceful
   shutdown. Probability is non-zero for any config that exercises unusual code paths in Mihomo.

2. **Hung `executor.ApplyConfig` (Scenario 1):** Goroutine blocked permanently. Zombie
   goroutine in the main process. Any attempt to restart creates split-brain on Mihomo globals.
   Only process restart provides a clean slate.

3. **Hung `executor.Shutdown` (Scenario 2):** Same as above, but during the shutdown path.
   The force-release path clears CAS and fd, but the zombie goroutine remains in Mihomo global
   executor state. New `ApplyConfig` in the same process races with the blocked `Shutdown`.

4. **Goroutine leak after timeout (Scenario 8):** Multiple zombie goroutines from repeated
   failed start/stop cycles accumulate in the process. Memory grows. Split-brain risk compounds.

**Under A2/A3 (isolated process):**
None of the above failures require restarting the main process. All are resolved by killing and
restarting the `:veercore` process or daemon. The unhandled goroutine panic terminates only the
Mihomo-host process, which Android's service restart mechanism (or `DeathRecipient`-triggered
restart) handles automatically.

The only failure class that remains in A2/A3 with no in-process recovery is:
- **Tun fd unrecoverable:** If the kernel closes the tun device before the `:veercore` process
  restarts (e.g., due to Android's VPN revocation), the `VeerVpnService` must call `establish()`
  again to get a new tun fd. This is the standard VPN reconnect flow and is expected.

---

## Conclusion

### Is the current in-process architecture fundamentally safe enough?

**For a development-phase tool with known operators: provisionally yes.**
**For production distribution to general users: no.**

The critical unsafety is the unhandled Mihomo background goroutine panic (Scenario 7b/7c). This
is not a theoretical risk. Mihomo's internal goroutines — DNS resolvers, proxy health checkers,
rule provider loaders — execute code paths that were never written with the guarantee that every
goroutine has a `defer recover()`. A nil pointer dereference in any of these goroutines terminates
the host process unconditionally. Under A1, that host process is the user's app.

For the Phase 1.1 scope (development, AI feature testing, personal use), the `base.yaml`
constraints (bundled/verified GeoIP data before TUN, no MMDB download through TUN) and the
engineMutex + `startAttempted` hardening reduce the probability of triggering the panic paths significantly. The architecture
is *stable under normal operation*, not fundamentally safe under all failure modes.

The second critical unsafety is the irrecoverable split-brain from hung goroutines. This becomes
a practical problem as soon as users encounter network conditions that cause `executor.ApplyConfig`
to stall (captive portals, flaky servers, unusual NAT). Under A1, each recovery attempt makes
the situation worse. Under A2, it is a process kill and clean restart.

### What failure classes remain impossible to recover regardless of architecture?

1. **Two simultaneous `ApplyConfig` calls in the same process** (split-brain): impossible to
   resolve without process death. The process isolation in A2/A3 moves this failure to be
   per-`:veercore`-process, not per-app-process, but does not eliminate it.

2. **Unhandled goroutine panic in Mihomo internals**: in A2/A3 this terminates only the
   Mihomo-host process. Process restart is automatic and transparent. The failure class persists
   but its impact radius shrinks from "app crash visible to user" to "VPN reconnects in 300–500ms
   with no UI disruption".

3. **Android VPN revocation by system**: regardless of architecture, if Android revokes VPN
   consent (e.g., another VPN app takes over, or the user toggles VPN off in system settings),
   the tun fd is invalidated. The `onRevoke()` callback fires and the VPN must be re-established.
   This is a platform constraint, not an architectural one.

### Should process isolation become a Phase 2 migration goal?

**Yes. The recommended target is Architecture A2 (Android isolated process) with the A4
(Binder AIDL) control plane.**

Rationale:

1. **A2 resolves all failure classes that require process restart under A1** without increasing
   user-visible disruption. The user never sees a crash dialog; they see "Reconnecting" for
   ~500ms.

2. **A2 preserves the gomobile toolchain.** The same `.aar` built from `go_core/` loads into
   the `:veercore` process. No architectural rethink of the Go layer is required. The cooperative
   lifecycle proposal (`runtime_lifecycle_proposal.md`) is still the Go-side target.

3. **A4 (Binder AIDL) provides typed, versioned, testable IPC.** The `IVeerCoreService.aidl`
   interface becomes a stable boundary that can be unit-tested independently of the Mihomo core.
   Kotlin Fakes (test doubles) can implement the AIDL interface to test UI behavior without
   running a real VPN.

4. **A3 (native daemon) is not recommended** for Veer's current phase. The debugging complexity,
   SELinux policy work (`android:extractNativeLibs`, `file_contexts` for the binary), and absence
   of Android Studio integration are not justified by the marginal memory saving over A2.

5. **A2 is the industry-standard approach** used by production Android VPN clients (Shadowsocks-
   Android, OpenVPN for Android, WireGuard). The pattern is well-understood, well-documented,
   and has known Android compatibility characteristics across API levels 26–35.

**Phase 2 migration scope:**

| Component | Migration action |
|---|---|
| `AndroidManifest.xml` | Add `android:process=":veercore"` to `VeerVpnService` |
| `IVeerCoreService.aidl` | Define `start(pfd, config)`, `stop()`, `getState()`, `registerCallback(cb)` |
| `IVeerCoreCallback.aidl` | Define `onStateChanged(state)`, `onLogEvent(level, msg)` |
| `MihomoEngine.kt` | Becomes a Binder client proxy that republishes state to `StateFlow` |
| `VeerVpnService.kt` | Adds Binder service implementation; removes direct `MihomoEngine.setState` calls |
| `MainActivity.kt` | No change — still observes `MihomoEngine.state: StateFlow<EngineState>` |
| `go_core/veer_core.go` | No change required (gomobile .aar loads identically in `:veercore`) |
| `docs/native_runtime_contract.md` | Appendix: fd transfer protocol over Binder |

The Phase 1.1 invariants (single Veercore.start/stop call site, engineMutex, startAttempted,
watchdog, EngineState sealed interface) remain valid and transfer directly to the Phase 2
architecture. They describe the Kotlin-side runtime contract, which the AIDL boundary extends
rather than replaces.
