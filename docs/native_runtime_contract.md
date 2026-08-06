# Veer Native Runtime Contract

Analysis of the JNI boundary between the Android Kotlin layer and the Mihomo
Go core (`libveer_core.aar`, built from `go_core/veer_core.go`).

All conclusions are derived from reading `veer_core.go` directly. Where Mihomo
internals (e.g., `executor.ApplyConfig`, `executor.Shutdown`) are referenced,
the analysis is based on observed behaviour and Mihomo's public API contract.

> 2026-08-05 update: this document preserves the original boundary analysis,
> while the implemented readiness gate, typed cross-process state, late-start
> cleanup ownership, synchronous resolver teardown, sing-tun detach fix and
> Gun raw-socket drain are authoritative in `docs/MIHOMO_CORE_AUDIT.md` and
> `docs/PHYSICAL_DEVICE_FULL_TEST_2026-08-05.md`. Older “current” limitations
> below should be read as the defect baseline when those two reports say they
> have been fixed and physically verified.

---

## 1. Call Inventory

| JNI call | Go symbol | Go signature |
|---|---|---|
| `Veercore.setLogger(l)` | `SetLogger` | `func SetLogger(l Logger)` |
| `Veercore.setProtector(p)` | `SetProtector` | `func SetProtector(p SocketProtector)` |
| `Veercore.start(homeDir, config, fd)` | `Start` | `func Start(homeDir, configName string, tunFd int32) error` |
| `Veercore.stop()` | `Stop` | `func Stop() error` |
| `Veercore.version()` | `Version` | `func Version() string` |

Calls the Go runtime makes back into the JVM (reverse-JNI):

| Go call | JVM target | Occurs |
|---|---|---|
| `l.Debug/Info/Warn/Error(msg)` | `VeerLogger` methods | From `forwardLogs` goroutine, any time after `SetLogger` |
| `p.Protect(fd)` | `SocketProtector.protect` | From Mihomo's outbound socket creation goroutines |

---

## 2. Blocking Analysis

### `Start` — **may block for seconds, unbounded**

`Start` is the most dangerous call at the JNI boundary.

1. `executor.Parse()` reads and parses YAML from disk. On a cold Android filesystem
   after a reboot, an uncached read of even a small file can take hundreds of
   milliseconds.
2. `executor.ApplyConfig(cfg, true)` is the long-duration work:
   - Resolves DNS servers (network I/O if not cached).
   - Loads GeoIP / GeoSite databases. If the MMDB is missing and the config
     references `geoip`, Mihomo **downloads it over the network**. Because the
     tun interface is now up and routing everything, this download goes through
     the tun itself unless the MMDB download socket is excluded from the tun via
     `SetProtector`. If the socket is not protected, the download routes through
     the tun that hasn't finished starting — **deadlock**.
   - Starts goroutines: inbound tun reader, REST API HTTP server, rule provider
     loaders (which may make further HTTP requests), health check timers.
   - Binds the Mihomo REST API listener on `127.0.0.1:9090`.

`Start` may block from ~200 ms (warm cache, no MMDB download) to indefinitely
(MMDB download deadlock, see §9.3 in `runtime_invariants.md`).

**Android-side obligation:** the Kotlin layer must not call `Start` on the main
thread or any thread whose starvation would cause an ANR. It must apply a
timeout (currently `STOP_TIMEOUT_MS = 6_000` covers stop; start has no
independent timeout — this is a gap, see §11).

### `Stop` — **may block, bounded by Mihomo drain behaviour**

`executor.Shutdown()` closes goroutines and drains connections. Mihomo does not
document a hard deadline; in practice it completes within 1–3 seconds with no
active connections, potentially longer if live TCP streams are draining.

The `defer recover()` in `Stop` means a panic during shutdown returns an error
rather than blocking indefinitely. However, a goroutine that is stuck in a
syscall (e.g., reading from the tun fd) cannot be interrupted by `Shutdown`.
The Android-side 6-second timeout in `tearDownCore` bounds the total wait.

### `SetLogger` — **non-blocking at call site; spawns goroutine**

The call itself is fast: mutex acquisition, channel close, goroutine start.
The spawned `forwardLogs` goroutine runs indefinitely until cancelled.

`SetLogger(nil)` closes `logCancel` and returns **without waiting** for the
old forwarder goroutine to finish executing. The goroutine exits asynchronously
at its next `select` branch. There is a brief window after `SetLogger(nil)`
returns in which the goroutine may still call `deliver()`, which will read
`logger = nil` (under `logMu`) and return without delivering. This is safe.

### `SetProtector` — **non-blocking**

Raw global assignment: `protector = p`. Returns immediately.

### `Version` — **non-blocking, always safe**

Stateless string return. No dependencies.

---

## 3. Thread Safety

| Call | Go-side protection | Safe for concurrent callers? |
|---|---|---|
| `SetLogger` | `logMu sync.Mutex` | **Yes** |
| `SetProtector` | None | **No** — raw write to package global |
| `Start` | None | **No** — no mutex in Go wrapper |
| `Stop` | None | **No** — no mutex in Go wrapper |
| `Version` | N/A (stateless) | **Yes** |
| `Logger` callbacks | `logMu` (read path) | **Yes** — goroutine-safe reads |
| `SocketProtector` callbacks | None in wrapper | Depends on JVM implementation |

`Start` and `Stop` have **no Go-side mutex**. The Go wrapper fully delegates
serialization to the caller. The Android-side `engineMutex` provides this.
If `engineMutex` is removed or bypassed, concurrent `Start`/`Stop` calls will
race on Mihomo's global executor state — the result is undefined.

`SetProtector` writes to `protector` without synchronization. Go's memory model
does not guarantee that this write is visible to goroutines started by a
subsequent `Start` call unless a happens-before relationship is established by
other means (mutex, channel, atomic). The JNI call boundary provides a
sufficient happens-before in practice (the OS thread executing the JNI frame is
sequentially consistent with itself), but this is implementation-defined, not
spec-guaranteed. `SetProtector` **must always be called before `Start`**, never
concurrently with it.

---

## 4. Reentrancy

**No JNI call in this contract is reentrant.**

Reentrancy here means: a call to X while X is already executing on any thread.

- `Start` calling `Start` again (before the first returns): races on
  `executor.ApplyConfig`'s global state. UB.
- `Stop` calling `Stop` again: races on `executor.Shutdown`. UB. A double
  `Shutdown` may panic (recovered) or corrupt internal maps.
- `SetLogger` is reentrant-safe (protected by `logMu`), but calling it from
  inside a `Logger` callback would deadlock: the callback is invoked under
  `logMu`, and `SetLogger` acquires `logMu`.

**Reverse reentrancy** (Go calls JVM which calls Go):

Mihomo's outbound socket creation calls `SocketProtector.Protect(fd)` on
whatever thread is creating the socket. If that JVM callback in turn calls any
`Veercore.*` method, it will attempt to enter the Go runtime while Go is already
executing inside a JNI call — this is undefined per JNI spec and will likely
deadlock or corrupt JNI state. **`SocketProtector` implementations must never
call any `Veercore.*` method.**

Similarly, `VeerLogger` callbacks must not call `Veercore.*`.

---

## 5. Required Serialization Order

The following ordering is mandatory, not advisory:

```
SetLogger(instance)       ← must complete before Start
SetProtector(instance)    ← must complete before Start
Start(homeDir, cfg, fd)   ← must complete (success or failure) before Stop
Stop()                    ← must complete before SetLogger(nil)
SetLogger(nil)            ← must complete before service destruction
```

Rationale for each ordering:

- **SetLogger before Start**: `executor.ApplyConfig` may emit log events during
  config apply. Without the logger installed first, those events are lost. Once
  `forwardLogs` is running, events from any subsequent `Start` call are captured.
- **SetProtector before Start**: Mihomo creates outbound sockets during
  `ApplyConfig` (health checks, rule provider downloads). If `protector` is nil
  at that point, those sockets are not protected from the tun routing loop.
- **Start before Stop**: `executor.Shutdown()` on a never-started Mihomo may
  panic. The `defer recover()` in `Stop` converts this to an error return, but
  the behaviour of Mihomo's global state after an unexpected `Shutdown` call is
  undefined. (Exception: calling `Stop` after a failed `Start` to clean up
  partial initialization — see §12.)
- **Stop before SetLogger(nil)**: Mihomo's log goroutines are still running
  during `Shutdown`. If `SetLogger(nil)` is called first, `logCancel` is closed
  and the forwarder exits, but Mihomo's log events have nowhere to go. More
  critically, `executor.Shutdown()` presumably closes Mihomo's internal log
  subscription channels; if the forwarder goroutine has already exited, those
  channels are just abandoned (see §7, Log Subscription Leak).
- **SetLogger(nil) before service destruction**: The `VeerLogger` JVM object
  will be eligible for GC once the service is destroyed. The `forwardLogs`
  goroutine holds a reference to the `logger` global (read under `logMu`). If
  the JVM object is collected and the goroutine calls into it, `deliver()`'s
  `defer recover()` catches the resulting NPE/ADE, but it is still a use-after-
  free at the JNI level. `SetLogger(nil)` nil-gates the delivery path and signals
  the goroutine to exit before the JVM object becomes unreachable.

---

## 6. Tun Fd Ownership Transfer

### Transfer mechanism

`Start(homeDir, configName, tunFd int32)` passes the tun fd as a 32-bit integer.
When `tunFd >= 0`, the Go side first duplicates it and sets:

```go
dupFd, err := syscall.Dup(int(tunFd))
cfg.General.Tun.FileDescriptor = dupFd
cfg.General.Tun.Inet4Address = []netip.Prefix{netip.MustParsePrefix("172.19.0.1/30")}
cfg.General.Tun.Inet6Address = []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}
```

The Android builder assigns the same interface addresses. Veer uses Mihomo's
`gvisor` TUN stack so TCP and UDP are processed fully in userspace; the AAR must
therefore be built with both `cmfa` and `with_gvisor`. A `cmfa`-only build
silently leaves only the `system` stack available, whose kernel TCP forwarder
is unreliable with this Android-owned fd even though UDP appears healthy.

**Verified correction (2026-06-30):** mihomo v1.18.10 does not parse a
`device: fd://N` value. Its sing-tun listener consumes the explicit
`FileDescriptor` field and wraps that descriptor with `os.NewFile`. The prior
contract text and bridge implementation conflicted with the pinned source and
caused sing-tun to attempt creating its own TUN, which failed with `permission denied`.
After `hub.ApplyConfig` returns:

- **Go holds a dup of fd N.** The integer `N` in Go's dup table is independent
  of the JVM's `ParcelFileDescriptor`.
- **The JVM-side `ParcelFileDescriptor` remains valid** and may be closed
  independently.

The bridge calls `hub.ApplyConfig(cfg)`, not `executor.ApplyConfig(cfg, true)`.
The latter excludes the external controller and would leave
`127.0.0.1:9090` unavailable. After `Start()` returns, Android does not publish
`Running` until both the native proxy tree and Controller `/version` pass the
bounded readiness gate. `Stop()` pairs `executor.Shutdown()` with an empty
`route.ReCreateServer` call to close the controller listener as well.

### Post-transfer semantics

After `Start` returns successfully:

1. The JVM may close `pfd` (via `tearDownTun`). This closes the JVM copy of fd N.
   The kernel will reclaim the fd table entry for the JVM process's copy only.
   Go's dup of fd N remains open and fully operational. Mihomo continues
   processing packets.
2. `Stop` must be called before the JVM destroys the tun session
   (`tearDownTun`). The correct order is Stop → tearDownTun.
   Calling tearDownTun before Stop leaves Go's tun goroutine reading from a fd
   whose JVM counterpart is closed. The underlying kernel file is still open (Go
   holds a dup), so packet delivery continues, but the VPN session is effectively
   unmanaged.
3. After `Stop()` completes, Go closes its dup of fd N (Mihomo's
   `Shutdown` tears down the inbound tun handler). The kernel file is then
   fully reclaimed.

### What "fd ownership" means in this contract

The tun fd is *shared* between JVM and Go from the moment `Start` is called
until `Stop` completes. Neither side has exclusive ownership during this window.
The JVM must not call `pfd.close()` until after `Stop` completes; Go must not
read from the fd after `Stop` completes. In the current implementation, the
ordering is:
```
Stop() → setLogger(null) → tearDownTun()
```
This is correct.

---

## 7. Failure Propagation Across JNI

### Go error → JVM exception

`Start` and `Stop` return `error`. gomobile maps a non-nil Go error to a
Java `Exception` thrown at the JVM call site. The Kotlin `runCatching { }` block
catches it as a `Throwable`. The `cause` field of the Kotlin `Throwable` contains
the Go error message.

The correct extraction pattern (used in `bootCore`):
```kotlin
val msg = t.cause?.message ?: t.message ?: t.toString()
```

### `defer recover()` coverage

Both `Start` and `Stop` use `defer func() { if r := recover(); r != nil { err = … } }()`.
This catches:

- Go panics triggered by Mihomo code during config parse or apply
- Nil pointer dereferences in Mihomo's global state
- Index-out-of-bounds during route table construction
- Any `panic(v)` call in the Mihomo dependency tree

After a recovered panic in `Start`, the function returns a non-nil `error`. The
Go stack has been unwound to the `defer` frame. Any goroutines that were started
before the panic point **continue running** — `recover()` only unwinds the
panicking goroutine's stack; it does not cancel other goroutines.

### What `deliver()`'s recover covers

The `forwardLogs` goroutine calls `deliver()`, which has its own
`defer func() { _ = recover() }()`. This catches panics in JVM logger callbacks
(e.g., `VeerLogger.debug` throwing an exception that propagates through JNI).
It prevents a buggy logger from crashing the Go runtime. It does **not** catch
panics in the `forwardLogs` goroutine itself (channel operations are not the
source of panics here).

---

## 8. Go Panic Behaviour

### Panic inside `Start`

1. `executor.Parse()` panics (e.g., internal Mihomo bug on malformed YAML that
   `Parse` didn't reject cleanly):
   - No goroutines have been started yet (ApplyConfig not called).
   - `recover()` catches it, `Start` returns error.
   - State: clean. No cleanup needed.

2. `executor.ApplyConfig` panics partway through:
   - Goroutines started before the panic site are still running.
   - `recover()` catches it, `Start` returns error.
   - State: **partially initialized**. Goroutines are orphaned.
   - The JVM sees `Start` return an error. `coreRunning` is never set to true.
   - The current teardown path skips `Veercore.stop()` (guarded by `coreRunning`).
   - **Orphaned goroutines hold the Go-side dup of the tun fd.** The kernel file
     stays open until all dups are closed. A subsequent `tearDownTun` on the JVM
     side closes the JVM dup, but Go's dup remains. The fd is not fully reclaimed.
   - **This is a resource leak and an invariant violation. See §12.**

### Panic inside `Stop`

1. `executor.Shutdown()` panics:
   - `recover()` catches it, `Stop` returns error.
   - State: partially shut down. Some Mihomo goroutines may still be running.
   - The JVM `runCatching { Veercore.stop() }.onFailure { … }` logs the error
     and continues teardown (closes tun, sets Stopped state).
   - Goroutines that survived the failed Shutdown continue running. The tun fd
     (Go's dup) remains open until those goroutines exit or the process dies.

### Unrecovered panics in non-JNI goroutines

A panic in a Mihomo goroutine that is NOT on the JNI call stack (e.g., the
`forwardLogs` goroutine, an inbound tun reader goroutine, a health check timer)
is **not covered by any `recover()`** unless Mihomo itself defers a recover in
that goroutine. If such a panic escapes to the Go runtime's top-level panic
handler, it crashes the entire process — **including the Android service host
process**.

gomobile does not install a global panic handler. Mihomo's internal goroutines
may or may not use `recover()` (this depends on Mihomo's own code quality).

**The current Kotlin watchdog provides detection but not prevention**: if Mihomo's
inbound goroutine panics and the process survives, the REST API will still be
unreachable, the watchdog will detect this within ~15–45 s, and initiate a clean
shutdown. If the goroutine panic crashes the process, Android restarts it via
`START_STICKY`.

---

## 9. Partial Initialization After Failed `Start`

When `Start` returns a non-nil error, two scenarios are possible:

**Scenario A — pre-ApplyConfig failure** (parse error, nil config, missing
home dir): No goroutines started. State is clean. No Go-side cleanup needed.

**Scenario B — mid-ApplyConfig panic**: Some subset of Mihomo's subsystems are
active. This includes potentially:
- The sing-tun inbound goroutine (holds dup of the tun fd)
- The REST API HTTP listener (port 9090 may be bound)
- DNS resolver goroutines
- Health check timers
- Rule provider loader goroutines (may have pending HTTP requests)

In Scenario B, calling `Stop()` (which calls `executor.Shutdown()`) is the
correct recovery action. `executor.Shutdown()` with `force=true`-equivalent
semantics should terminate all active subsystems regardless of whether they
were fully initialized. The `defer recover()` in `Stop` makes this call safe
even if `Shutdown` panics on unexpected state.

The current Kotlin implementation **does not call `Stop()` after a failed
`Start()`**, relying on the `coreRunning` guard. This is a defect — see §Audit.

---

## 10. Android-Side Timeout Responsibilities

The Go wrapper does not enforce any timeouts. All time bounds are the Android
layer's responsibility.

| Operation | Current timeout | Adequate? |
|---|---|---|
| `Start` (via `bootCore`) | None — runs until completion or panic | **No** |
| `Stop` (via `tearDownCore`) | 6 000 ms via `withTimeoutOrNull` | Adequate |
| `SetLogger` | Effectively instant (goroutine async) | Adequate |
| `SetProtector` | Effectively instant | Adequate |

**`Start` has no Android-side timeout.** If `executor.ApplyConfig` hangs
(deadlock in MMDB download, blocked DNS resolution, hung rule provider fetch),
`bootCore` blocks indefinitely on an IO thread inside `engineMutex`. The mutex
remains held. If `stopSelf()` is subsequently called (e.g., user taps Stop),
`onDestroy` runs `runBlocking { tearDownCore() }`, which attempts to acquire the
mutex. The mutex is held by the stuck `bootCore`. `tearDownCore` suspends. The
`withTimeoutOrNull(6_000)` fires after 6 s, but at this point `bootCore` is
still holding the mutex and still blocking inside JNI — the coroutine cannot be
cancelled because it is inside a non-cancellable JNI call.

Result: the 6-second timeout fires, `tearDownTun` is called forcefully, and
`serviceScope.cancel()` is invoked. But `bootCore`'s JNI thread (`Veercore.start`)
is still blocked. The Android service is destroyed. The JNI thread continues
running in a destroyed service context.

**Recommendation:** wrap `bootCore`'s `Veercore.start` call in a separate
`withTimeoutOrNull` that is independent of the stop timeout. Because JNI calls
are not cancellable, the timeout cannot interrupt the call — it can only mark the
service as failed and proceed with tun teardown in parallel. See §Audit.

---

## 11. Safety of Calls During Teardown

"During teardown" means after `onDestroy` has been called and
`MihomoEngine.setState(EngineState.Stopping)` has been set, but before `Stop`
has returned.

| Call | Safe? | Notes |
|---|---|---|
| `Version()` | **Yes** | Stateless |
| `SetLogger(nil)` | **Yes** | Must be called after `Stop` — see §5 |
| `SetLogger(instance)` | **No** | Replaces logger while Stop's goroutines are winding down; new forwarder starts on dying subscription |
| `SetProtector(nil)` | **Unsafe** | If Mihomo goroutines are still creating sockets during `Shutdown`, a nil protector causes routing loops |
| `Start(…)` | **No** | `engineMutex` prevents this on the Kotlin side; if called concurrently on the Go side, races with `Shutdown` |
| `Stop()` | **No** (second call) | Double-shutdown races on Mihomo's global state; the `defer recover()` converts the panic to an error but state is undefined |

---

## 12. Recovery Assumptions After Failed `Start()`

After `Start()` returns a non-nil error, the following sequence is required for
a clean recovery:

```
1. Call Stop()        — attempt to terminate any partially-initialized subsystems.
                        The defer recover() in Stop makes this safe even if
                        Shutdown() panics on unexpected partial state.
2. Call SetLogger(nil) — prevent the forwardLogs goroutine from delivering
                         events into an object that may be collected.
3. Close the tun fd   — tearDownTun().
4. Do NOT call Start() again until all three steps above have completed.
```

If the tun fd is reused (i.e., `Builder.establish()` is called again to get a
new fd), Mihomo from the partial initialization may still hold a dup of the old
fd. The kernel will not reclaim the underlying tun device until all dups across
all goroutines are closed. On some Android kernels, having two active dups of
different tun sessions may cause packet routing ambiguity.

A safe reconnect sequence after any failed start:
```
Stop()  →  SetLogger(nil)  →  tearDownTun()  →  [wait]
  →  SetLogger(new)  →  SetProtector(new)  →  [new establish()]  →  Start()
```

The `[wait]` step has no deterministic completion signal from the Go side.
The watchdog's initial 15-second delay approximates this: if the REST API
becomes reachable, partial goroutines have been cleaned up.

---

## Audit: Current Call Sites Against the Contract

### File: `VeerVpnService.kt` — `bootCore()`

```kotlin
runCatching { Veercore.setLogger(VeerLogger(logDir)) }
runCatching { Veercore.setProtector(...) }
// ...
runCatching { Veercore.start(homeDir, BASE_CONFIG, pfd.fd) }
    .onFailure { t ->
        // ...
        tearDownTun()
        stopSelf()
        return
    }
coreRunning = true
// Running is still unpublished here. Verify native routing state and the
// local Controller in the same bounded readiness attempt first.
```

**V1 — ~~VIOLATION~~ FIXED: partial initialization cleaned up via `startAttempted` flag**

`startAttempted: Boolean` (declared `@Volatile`) is set to `true` immediately
before `Veercore.start()` is called and reset to `false` in `tearDownCore()`
after `Veercore.stop()` completes. `tearDownCore` now calls `Veercore.stop()`
when `coreRunning || startAttempted`, covering both the normal running case
and the partial-initialization case:

```kotlin
// bootCore — set flag before the JNI call
startAttempted = true
runCatching { Veercore.start(homeDir, BASE_CONFIG, pfd.fd) }
    .onFailure { ... tearDownTun(); stopSelf(); return }

// tearDownCore — stop if start was ever attempted
if (coreRunning || startAttempted) {
    runCatching { Veercore.stop() }
    coreRunning = false
    startAttempted = false
}
```

This preserves the invariant that `Veercore.stop()` is called ONLY from
`tearDownCore()` — no second call site is needed.

---

**V2 — GAP (unfixable at Kotlin level): `Start()` has no effective timeout**

`bootCore` calls `Veercore.start` with no timeout. A hung `executor.ApplyConfig`
(MMDB download deadlock, blocked DNS) holds `engineMutex` indefinitely.

**Why `withTimeoutOrNull` cannot help here:**
`withTimeoutOrNull(T) { runCatching { Veercore.start(...) } }` does not
interrupt the JNI call. `Veercore.start` is not a Kotlin suspension point.
The timeout only fires *after* the JNI call returns: it marks the coroutine as
cancelled, then `runCatching` catches the `CancellationException`, then the
coroutine exits. The JNI thread is never interrupted. Adding this timeout would
not reduce hang duration — it would only change what happens after the hang
finally ends.

**Consequence of a hung start:** if `onDestroy` fires while `bootCore` holds
`engineMutex` inside the JNI call, `tearDownCore` suspends on the mutex. The
`withTimeoutOrNull(6_000)` fires, force-closes the tun, destroys the service,
and cancels the scope. The JNI thread continues running in the destroyed
service's context until `ApplyConfig` completes or panics.

**Current mitigations:**
- Imported `dns.fallback:` and `fallback-filter` are preserved so polluted
  primary DNS answers can be rejected. `GeoDatabaseManager` installs and
  verifies bundled `geoip.metadb` before config validation; startup fails
  before TUN establishment if it is unavailable. This removes the
  MMDB-download-through-TUN deadlock while retaining correct DNS behavior.
- `SetProtector` is installed before `Start`, so any outbound sockets created
  during `ApplyConfig` bypass the tun and cannot form a routing loop.
- The MMDB download, if triggered by a `geoip` rule, goes through the protected
  path and reaches the real network.

**Real fix:** requires a Go-side cancellation signal — a `context.Context`
parameter on `Start` that `executor.ApplyConfig` checks at yield points. This
requires modifying `veer_core.go` and re-running `gomobile bind`. Until then,
this gap is accepted and mitigated by the `base.yaml` constraints.

---

### File: `VeerVpnService.kt` — `tearDownCore()`

```kotlin
if (coreRunning) {
    runCatching { Veercore.stop() }
}
runCatching { Veercore.setLogger(null) }
tearDownTun()
```

**Compliant** with respect to:
- § 5 ordering (Stop before SetLogger(nil) before tearDownTun) ✓
- § 3 (Stop is not called concurrently — mutex held) ✓
- § 11 (SetLogger(nil) after Stop) ✓

**Note:** The `coreRunning` guard correctly prevents a double-`Stop` in the
normal case. However, due to **V1**, a failed `Start` means `coreRunning == false`
while Mihomo goroutines may be running. The guard skips the cleanup. This is
the same violation as V1, observed from the teardown side.

---

### File: `VeerVpnService.kt` — `bootCore()` — protector installation

```kotlin
runCatching {
    Veercore.setProtector(object : SocketProtector {
        override fun protect(fd: Int): Boolean = this@VeerVpnService.protect(fd)
    })
}
```

**Compliant** — called before `Veercore.start()`, inside `engineMutex`. ✓

**Note on JVM callback safety:** the `SocketProtector` anonymous object calls
`this@VeerVpnService.protect(fd)`. `VpnService.protect(fd)` is thread-safe per
Android documentation. The `this@VeerVpnService` reference will survive as long
as Go holds the `protector` global — which is until the next `SetProtector` call
or process death. If the service is destroyed and a Mihomo goroutine calls
`protect()` after destruction, `VpnService.protect()` on a destroyed service
returns `false` (does not throw). This is safe.

---

### File: `VeerVpnService.kt` — logger installation

```kotlin
runCatching { Veercore.setLogger(VeerLogger(File(filesDir, "logs"))) }
    .onFailure { MihomoEngine.publishLifecycleLog("setLogger failed: ${it.message}") }
```

**Compliant** — called before `Veercore.start()`. ✓

**Log subscription leak (cosmetic):** When `SetLogger(nil)` is called later,
`logCancel` is closed but the `log.Subscribe()` subscription is not
unsubscribed from Mihomo's publisher. Mihomo will continue sending events to the
abandoned channel. Because `executor.Shutdown()` is called before
`SetLogger(nil)` in the teardown sequence, Mihomo's shutdown should close its
internal log publisher, which closes the subscription channel, causing
`forwardLogs` to exit via the `case ev, ok := <-sub: if !ok { return }` branch.
This is the correct cleanup path. The leak only materialises if `SetLogger(nil)`
is called without a preceding `Stop()` — which the current teardown sequence
never does.

---

### File: `VeerLogger.kt` — `persist()` called from forwarder goroutine

```kotlin
private fun persist(level: String, msg: String) {
    runCatching {
        file.appendText(...)
    }
}
```

`persist` is called from the `forwardLogs` goroutine (a Go goroutine calling
into JVM). `File.appendText` triggers disk I/O on the goroutine's OS thread.
Go goroutines have small stacks (initially 2–8 KB, growable). JNI calls from
Go goroutines run on the goroutine's stack, but JNI frames can grow it. The I/O
call itself runs on the OS thread borrowed by the goroutine. This is safe but
may add latency to log delivery.

`runCatching` swallows `IOException` (disk full, permission denied). ✓
The goroutine's own `deliver()` has `defer recover()` as a secondary guard. ✓

---

## Summary Table

| ID | Severity | Finding | Status |
|---|---|---|---|
| V1 | **Critical** | Failed `Start()` does not call `Stop()` — partial Mihomo goroutines orphaned, tun fd dup leaked | **Fixed** — `startAttempted` flag; `tearDownCore` calls `Stop()` on `coreRunning \|\| startAttempted` |
| V2 | **High** | `Start()` has no effective timeout — `withTimeoutOrNull` cannot interrupt a blocking JNI call | **Unfixable at Kotlin level** — mitigated by `base.yaml` constraints; real fix requires Go-side `context.Context` on `Start` |
| UB1 | Low | `SetProtector` write has no Go-side mutex — technically a data race per Go memory model | Accepted — safe in practice due to JNI call boundary ordering; not fixable on Kotlin side |
| RISK1 | Low | Log subscription channel not explicitly unsubscribed on `SetLogger(nil)` | Accepted — mitigated by `executor.Shutdown()` closing channels before `SetLogger(nil)` is called |
| RISK2 | Informational | Unrecovered panics in non-JNI Mihomo goroutines can crash the host process | Accepted — mitigated by watchdog detection + `START_STICKY` restart; not fixable without modifying Mihomo internals |
