# Veer Android Runtime Invariants

This document defines the runtime and lifecycle invariants of the Veer VPN
service layer. Every invariant is intentional. Before modifying `VeerVpnService`,
`MihomoEngine`, `VeerLogger`, or the Go core binding, read the relevant section
and understand why the constraint exists before deciding whether to relax it.

---

## 1. Runtime Ownership

### 1.1 Sole caller of `Veercore.start`

`Veercore.start(homeDir, configFile, fd)` **must only be called from
`VeerVpnService.bootCore()`.**

Never call it from:
- `MihomoEngine` (state/log object only, no orchestration)
- `AiController` or any `core_ai` class
- `MainActivity` or any Compose layer
- `MihomoRepository` or any data layer
- A `ViewModel`, `Repository`, or `Application` subclass

**Rationale.** `Veercore.start` hands a live tun file descriptor into the Go
runtime and binds the Mihomo engine's goroutine pool to it. The fd is only valid
within the VPN session established by `VpnService.Builder.establish()`. That
session is owned by `VeerVpnService`. Calling `Veercore.start` outside the
service either passes an invalid fd (crash in Go) or creates a runtime bound to
a fd the service does not know about (can never be torn down cleanly).

### 1.2 Sole caller of `Veercore.stop`

`Veercore.stop()` **must only be called from `VeerVpnService.tearDownCore()`.**

`tearDownCore` is reached only from service-owned lifecycle paths:

```kotlin
requestShutdown(...)       // explicit STOP/watchdog/revoke/error path
requestReconnect()         // same-instance user fast reconnect
prepareForProfileSwitch()  // retained-service config switch boundary
onDestroy()                // Android lifecycle fallback
```

All stop paths — `ACTION_STOP` intent, watchdog-detected failure,
and `onRevoke()` — converge on `requestShutdown()`. It atomically admits one
shutdown request, sets `Stopping`, calls `tearDownCore()`, then calls
`stopSelf()`. Android may keep an active `VpnService` bound while its tun is
open, so relying on `stopSelf()` to trigger `onDestroy()` creates a lifecycle
cycle. A direct system destroy uses the same `tearDownCore()` as a fallback.
There is still exactly one native shutdown function and `engineMutex` makes
repeat teardown calls idempotent.

**Rationale.** If `Veercore.stop` is called from two places concurrently, the
Go runtime can be double-freed. If it is called before `onDestroy` (e.g., from a
`ViewModel`), the tun fd may still be open and Android will not revoke the VPN
session, leaving a zombie tunnel. Centralising the call in `tearDownCore` under
the mutex means the Android service lifetime and the Go runtime lifetime are
identical.

### 1.3 At most one live Go runtime

At any moment, at most one instance of the Mihomo engine may be running inside
the process. This is enforced by two independent mechanisms:

1. **Android VpnService constraint.** A package may only have one active
   `VpnService` at a time. A second `startForegroundService` while one is
   active merely delivers a new `onStartCommand`; it does not create a second
   service instance.

2. **`engineMutex` + `coreRunning` guard.** Even within a single service
   instance, `bootCore` checks `coreRunning` as its first action inside the
   mutex. If true it logs and returns immediately. Concurrent `ACTION_START`
   deliveries serialize at the mutex and the second one exits early.

**Rationale.** Two live runtimes would bind two goroutine pools to the same tun
fd (or two different fds with only one routed by the kernel). The result is
undefined packet routing, potential fd exhaustion, and unrecoverable Go heap
corruption if both runtimes later call `stop()`.

### 1.4 Start and stop are always serialized by `engineMutex`

`bootCore()` and `tearDownCore()` each call `engineMutex.withLock { … }` as
their outermost action. Neither executes any state mutation outside the mutex.

`coreRunning`, `tunInterface`, `MihomoEngine.setState(…)`, and
`Veercore.setLogger(…)` are only mutated from inside a held lock.

**Rationale.** Consider rapid connect/disconnect: the user taps Start, then
immediately taps Stop before the Go core has finished initialising. Without the
mutex, `tearDownCore` could observe `coreRunning == false` (not yet set by
`bootCore`), skip `Veercore.stop()`, return, and then `bootCore` sets
`coreRunning = true` — leaving a live runtime with no shutdown path. The mutex
eliminates this window.

---

## 2. Tun Lifecycle

### 2.1 Ownership

The `tunInterface: ParcelFileDescriptor` field is the sole handle to the VPN
tun device. It is:

- Written once inside `bootCore`, immediately after `Builder.establish()` succeeds.
- Nulled in `tearDownTun()`, which is called from `tearDownCore()` and from
  forced-cleanup fallbacks.
- Never returned, passed, or published to any caller outside `VeerVpnService`.
- Declared `@Volatile` so the watchdog's non-mutex read of `tunInterface` sees
  the most recent write without acquiring the mutex.

### 2.2 Fd handoff to Go

`Veercore.start(homeDir, configFile, pfd.fd)` passes the integer fd to Go.
Go calls `dup()` internally and owns its own copy. After this call:

- The JVM-side `pfd` (and therefore `tunInterface`) may be closed without
  invalidating the Go-side dup.
- Closing `tunInterface` in `tearDownTun` signals the Go side that the VPN
  session is ending, but does **not** itself stop the Go goroutines. `Veercore.stop()`
  must be called first so the goroutines drain before the fd disappears.

**Correct teardown order** (enforced by `tearDownCore`):
1. `Veercore.stop()` — Go goroutines drain, Go-side dup closed.
2. `Veercore.setLogger(null)` — detach logger so winding-down goroutines
   cannot deliver events into a GC'd `VeerLogger` JVM object.
3. `tearDownTun()` — close JVM-side `ParcelFileDescriptor`.

Reversing steps 1 and 3 risks a Go goroutine writing to the fd after the kernel
reclaims it (EBADF or, worse, writing into a fd reused for a different purpose).

### 2.3 Teardown guarantee

`tearDownTun()` is called in three places, all safe:

| Call site | Condition |
|-----------|-----------|
| `tearDownCore()` | Normal shutdown path, inside mutex |
| `requestShutdown()` catch | Force-close if `tearDownCore` throws |
| `onDestroy()` timeout handler | Force-close if `tearDownCore` mutex-wait exceeds `STOP_TIMEOUT_MS` |

`tearDownTun()` is idempotent: it wraps `tunInterface?.close()` in
`runCatching`, then sets `tunInterface = null`. Calling it twice is safe.

### 2.4 Forced close

`VeerVpnService` uses a two-layer timeout for teardown:

**Layer 1 — `STOP_TIMEOUT_MS` (4 s, `withTimeoutOrNull`):** bounds how long
`onDestroy` waits to *acquire* `engineMutex`. If `bootCore` holds the mutex for
longer than this (e.g. during a long `Veercore.start()` JNI call), the coroutine
is cancelled at the mutex suspension point and `onDestroy` force-closes the tun fd
directly, setting state to `Stopped`.

**Layer 2 — `STOP_JNI_TIMEOUT_MS` (5 s, `CountDownLatch`):** bounds the
`Veercore.stop()` JNI call itself, once `tearDownCore` is already inside the
mutex. `Veercore.stop()` runs on a dedicated daemon thread; the latch gives a
real platform timeout that fires even when a JNI frame holds the calling thread
(unlike `withTimeoutOrNull`).

If the JNI latch fires:
- The daemon thread is orphaned — it continues running `executor.Shutdown()` in Go.
- The service transitions to **`EngineState.Error`** (not `Stopped`). This is the
  `Stopping → Error` path (see §3.2). Reconnecting while a zombie
  `executor.Shutdown()` goroutine is active risks Mihomo global-executor split-brain
  (runtime_nonrecoverable_states.md Scenario 8). The user must force-stop and reopen
  the app before reconnecting.
- `serviceScope.cancel()` terminates the watchdog and all cooperative coroutines.

Worst-case `onDestroy` duration ≈ `STOP_TIMEOUT_MS` + `STOP_JNI_TIMEOUT_MS` = 9 s.

The Go runtime may still be running after either timeout fires, but:

- The Go-side dup of the fd is now backed by a kernel fd that the VPN session
  has released. Further writes from Go will return EBADF and Go's error handling
  will surface this.
- Android's VPN stack reclaims the tun device. Traffic stops being routed
  regardless of Go's state.
- The `serviceScope.cancel()` call following the timeout will terminate the
  watchdog and any other coroutines at their next suspension point.

### 2.5 No fd reuse after teardown begins

Once permanent shutdown begins, `shutdownStarted` prevents a new runtime from
starting until `tearDownCore` has fully drained the old runtime. An ACTION_START
received during active teardown is recorded as `restartAfterShutdownRequested`;
it is resumed only after state is truthfully `Stopped`, `coreRunning` and
`startAttempted` are false, and no JNI stop timeout occurred. A user fast
reconnect follows the same safety boundary without the intermediate Stopped
frame: `requestReconnect()` first completes `tearDownCore(finalizeState=false)`
and only then calls `bootCore()`. Both paths serialize through `engineMutex`, so
the new `Builder.establish()` and `Veercore.start()` cannot reuse or overlap the
old tun fd/runtime.

### 2.6 LAN bypass is symmetric across address families

With `BYPASS_LAN` enabled, the Android-owned route table leaves these
destinations on the underlying network:

- IPv4 RFC1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- IPv4 link-local and multicast: `169.254.0.0/16`, `224.0.0.0/4`
- IPv6 ULA: `fc00::/7`
- IPv6 link-local: `fe80::/10`

On API 33+, `VpnService.Builder.excludeRoute()` installs throw routes for those
seven prefixes over the IPv4 and IPv6 defaults. On API 29–32,
`VpnRoutePolicy` installs exact, non-overlapping CIDR complements because
`excludeRoute()` is unavailable. The fallback must never also add `0.0.0.0/0`
or `::/0`, because either default would recapture the ranges being bypassed.

The TUN's own `fdfe:dcba:9876::/126` connected route is more specific than the
ULA throw route and remains attached to the TUN. IPv6 multicast `ff00::/8` and
deprecated site-local `fec0::/10` remain tunneled unless a separate routing
policy changes them.

---

## 3. EngineState Invariants

### 3.1 State machine

```
         ┌──────────────┐
         │    Stopped   │◄──────────────────────────┐
         └──────┬───────┘                           │
                │ bootCore acquired mutex             │
                ▼                                    │
         ┌──────────────┐                           │
         │   Starting   │                           │
         └──────┬───────┘                           │
         ╱             ╲                            │
   success               failure                    │
       │                    │                       │
       ▼                    ▼                       │
 ┌──────────┐         ┌──────────┐                  │
 │  Running │         │  Error   │──────────────────┤
 └────┬─────┘         └──────────┘  (→ shutdown)    │
      │                                             │
      │ onDestroy / watchdog failure → Error         │
      ▼                                             │
 ┌──────────┐     normal stop ──────────────────────►┘
 │ Stopping │
 └──────────┘     JNI stop timeout ─────────────────► Error
                  (Stopping → Error; see §3.2)
```

### 3.2 Legal transitions

| From | To | Trigger |
|------|-----|---------|
| `Stopped` | `Starting` | `bootCore` acquires mutex, `coreRunning == false` |
| `Starting` | `Running` | `Veercore.start` returns without exception, `coreRunning = true` |
| `Starting` | `Error` | tun establish null, config prepare failure, `Veercore.start` exception |
| `Running` | `Error` | watchdog detects API unreachable; `CoroutineExceptionHandler` fires |
| `Running` | `Stopping` | shutdown, profile switch, fast reconnect, or system `onDestroy()` begins teardown |
| `Error` | `Stopping` | an error path calls `requestShutdown()` |
| `Stopping` | `Stopped` | explicit shutdown/profile preparation completes; `onDestroy` finishes; or a force-close path runs |
| `Stopping` | `Starting` | fast reconnect has completely drained the old runtime and immediately calls `bootCore()` |
| `Stopping` | `Error` | `Veercore.stop()` JNI call times out (`STOP_JNI_TIMEOUT_MS`); daemon thread orphaned; reconnect unsafe (see §2.4 and runtime_nonrecoverable_states.md §8) |

### 3.3 Forbidden transitions

- **Any state → `Running` directly.** `Running` is only reachable through `Starting`. Skipping `Starting` would mean the tun and logger were never set up.
- **`Stopped` → `Stopping`.** There is nothing to stop. `onDestroy` must only be reached when the service was started.
- **`Running` → `Starting`.** The mutex and `coreRunning` guard prevent this. A second start while running is a silent no-op, not a restart.
- **`Stopping` → `Error` from any path other than JNI stop timeout.** `Stopping → Error` is legal exactly when `Veercore.stop()` times out (§3.2). It must not be used as a general "error during shutdown" catch-all — doing so would conflate the process-restart-required case with ordinary errors.
- **Any transition from outside `VeerVpnService`.** `MihomoEngine.setState` is `internal` to the `core_mihomo` module. UI and AI layers are observers only.

### 3.4 Error semantics

`EngineState.Error(message: String)` means:

1. An unrecoverable fault has been detected.
2. `requestShutdown()` has been or will be called shortly after.
3. **The Go runtime may still be running.** `Error` is not a guarantee of
   shutdown — `Stopping` and `Stopped` are.
4. The `message` field is the first available cause string: `t.cause?.message`,
   then `t.message`, then `t.toString()`.

UI should treat `Error` as "shutting down, see message" — not "stopped safely."
Distinguishing `Error` from `Stopped` is important for deciding whether to offer
a reconnect button (reconnect makes sense after `Stopped` via a normal stop, not
necessarily after `Error` without diagnosing the cause).

### 3.5 Stopping semantics

`EngineState.Stopping` is set when `requestShutdown()` wins its atomic gate, or
by `onDestroy()` for a system-initiated destroy. It means:

1. The service has received a definitive shutdown signal.
2. `tearDownCore` will be attempted.
3. `Veercore.stop()` will be called (or the `STOP_JNI_TIMEOUT_MS` latch will fire).
4. No new `bootCore` can produce a `Running` state after this point.

`Stopping` exits via one of two terminal states:
- **`Stopped`** — normal completion: `Veercore.stop()` returned before the JNI latch expired.
- **`Error`** — JNI stop timed out: daemon thread is orphaned (see §2.4 and §3.2).

`Stopping` is not an intermediate state that can be cancelled or reversed.

---

## 4. Coroutine Model

### 4.1 Service scope

```kotlin
CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { … })
```

All coroutines launched by `VeerVpnService` are children of this scope.

### 4.2 `SupervisorJob` rationale

Under a regular `Job`, any child failure cancels all siblings and the parent.
Under `SupervisorJob`, each child fails independently. This means:

- A watchdog coroutine that throws (e.g., OkHttp internal error) does not cancel
  `bootCore` or any other child.
- The `CoroutineExceptionHandler` is invoked for each uncaught child failure
  individually, setting `Error` state and logging — the service remains alive.

Without `SupervisorJob`, a single transient exception in any background coroutine
would silently tear down the entire scope, leaving the Go runtime running with no
watchdog and no way to observe the failure.

### 4.3 `Dispatchers.IO` and deadlock avoidance

The scope's default dispatcher is `Dispatchers.IO`, not `Dispatchers.Main`. This
is deliberate.

`onDestroy` calls `runBlocking { … }` on the Android **main thread**. Inside
`runBlocking`, the main thread runs an embedded event loop. For a deadlock to
occur, a coroutine inside `runBlocking` would need to resume on the main thread
while the main thread is blocked waiting for that coroutine. Since `bootCore`
and `tearDownCore` resume on `Dispatchers.IO` threads (not `Dispatchers.Main`),
there is no circular dependency. The main thread waits in the `runBlocking` event
loop; IO threads make progress and release the mutex; `tearDownCore` resumes in
the event loop. No deadlock.

If the scope were `Dispatchers.Main`, `bootCore`'s continuations after
`withContext(Dispatchers.IO)` would need to resume on Main — which is blocked by
`runBlocking` — producing a deadlock.

### 4.4 Cancellation guarantees

- `serviceScope.cancel()` is called in `onDestroy` after `runBlocking` completes.
  This cancels all remaining children at their next suspension point.
- `delay(…)` is a cancellable suspension point. The watchdog's `delay` calls
  will be interrupted promptly by the cancellation.
- **JNI calls (`Veercore.start`, `Veercore.stop`) are not cancellable.** A
  coroutine blocked in a JNI call will not respond to `cancel()`. The two-layer
  timeout in `onDestroy` bounds teardown duration from the Android side:
  `STOP_TIMEOUT_MS` (4 s, `withTimeoutOrNull`) bounds the mutex-wait phase;
  `STOP_JNI_TIMEOUT_MS` (5 s, `CountDownLatch`) bounds the JNI call once inside
  the mutex. After both timeouts, `serviceScope.cancel()` terminates all
  cooperative coroutines, but an orphaned JNI daemon thread continues until the
  native call returns or the process dies.

### 4.5 Teardown synchronization

The normal explicit teardown sequence is:

```
(service IO scope)
  requestShutdown() atomic gate
  setState(Stopping)
  tearDownCore(finalizeState=false) under engineMutex
  setState(Stopped) // after normal, recoverable teardown
  if ACTION_START was queued:
    reopen shutdown gate
    bootCore()
  else after SHUTDOWN_DESTROY_GRACE_MS:
    stopForeground(...)
    stopSelf()
(main thread)
  onDestroy()
  tearDownCore(finalizeState=true) // idempotent fallback
```

`onDestroy()` then runs the idempotent fallback below. If explicit teardown
already completed, it observes no live runtime and returns quickly. For a
system-initiated destroy, it performs the real teardown:

```
(main thread)
  setState(Stopping)
  runBlocking {
      withTimeoutOrNull(STOP_TIMEOUT_MS=4000ms) {    ← bounds mutex-wait only
          tearDownCore() {
              coreRunning = false                     ← cleared before CM.stop() to
              connectivityMonitor.stop()              ←   prevent in-flight callback race
              [if needsStop]:
                  Thread({ Veercore.stop() }).start() ← daemon thread; JNI may block
                  CountDownLatch.await(STOP_JNI_TIMEOUT_MS=5000ms)
                  [if timed out]: stopTimedOut=true   ← orphaned thread path
              Veercore.setLogger(null)
              tearDownTun()
              if (stopTimedOut) setState(Error)       ← Stopping→Error (§3.2, §3.5)
              else              setState(Stopped)
          }
      } ?: forceClose() {                            ← only if mutex-wait exceeded 4s
          tearDownTun()
          setState(Stopped)
      }
  }
  serviceScope.cancel()                              ← cooperative cancellation
  super.onDestroy()
```

`runBlocking` must complete before `serviceScope.cancel()` so that
`tearDownCore`'s coroutine (which is a child of `serviceScope`) is not cancelled
mid-execution by the scope cancellation.

---

## 5. Watchdog Guarantees

### 5.1 Observation only — no direct core control

The watchdog **never calls `Veercore.stop()` directly.** It may only:

1. Set `EngineState.Error`.
2. Call `requestShutdown()`.

`requestShutdown()` calls `tearDownCore()` under the mutex and only calls
`stopSelf()` after the runtime and tun are down. This preserves invariant 1.2
(sole native-stop caller) and invariant 1.4 (mutex serialization), without
depending on Android to destroy a still-bound active VPN service.

If the watchdog called `Veercore.stop()` directly, it would bypass the mutex,
race `bootCore`, and potentially double-free the Go runtime.

### 5.2 Check mechanism

The watchdog polls `MihomoRepository.get().version()` (HTTP GET `/version`).
This call has a 2-second connect timeout and a 5-second read timeout. A `null`
return means either:

- The Mihomo HTTP server goroutine has exited (Go runtime crash or panic).
- The local socket is not yet bound (race during startup — mitigated by the
  15-second initial delay).
- An Android ROM is blocking localhost traffic (MIUI, HyperOS).

The watchdog does not distinguish these cases. It therefore requires three
consecutive `null` responses after the grace period before treating the fault
as fatal. Any successful response resets the failure count to zero.

### 5.3 Initial delay rationale

`WATCHDOG_INITIAL_DELAY_MS = 15_000L`. The Mihomo REST server binds its listener
as part of `executor.ApplyConfig`, which happens after config parsing, DNS setup,
and proxy provider loading. On a cold start with a large config this can take
several seconds. Polling before the listener is ready would generate a false
positive that forces an immediate teardown.

If the grace period proves too short for a specific device, increase it in the
companion object. Do not remove it.

**Phase 1.2 SI-01 implemented:** `WatchdogFailureTracker` requires three
consecutive failed probes (the initial failure plus two retries). A healthy
probe between failures resets the streak. With the default 30-second interval,
this preserves liveness detection while tolerating brief network handoffs.

### 5.4 Watchdog lifecycle

The watchdog coroutine is launched as a child of `serviceScope`. It is cancelled
by `serviceScope.cancel()` in `onDestroy`. The watchdog's `delay(…)` calls are
cooperative cancellation points. A watchdog sleeping between checks when the
service is destroyed will be cancelled within one scheduler tick of
`serviceScope.cancel()`.

The watchdog is also naturally terminated if `coreRunning` becomes `false` (it
checks `while (isActive && coreRunning)`) — for example, after the teardown
timeout forces `coreRunning = false` before `serviceScope.cancel()` runs.

---

## 6. Failure Handling

### 6.1 All runtime failures must produce observable state

Every failure path inside `bootCore` and `tearDownCore` must call
`MihomoEngine.setState(EngineState.Error(…))` before returning. Leaving the
state as `Starting` or `Running` after a failure would leave the UI in a state
that no longer reflects reality and could enable the user to submit AI commands
to a dead proxy.

The `CoroutineExceptionHandler` on `serviceScope` is a last-resort backstop: it
catches uncaught exceptions from any child coroutine, sets `Error` state, and
logs the message. It does not substitute for explicit error handling in
`bootCore`; it catches faults that occur outside the try/catch blocks (e.g.,
inside the watchdog's HTTP call, in future coroutines added to the scope).

### 6.2 No silent coroutine death

`SupervisorJob` + `CoroutineExceptionHandler` together guarantee that:

- No child coroutine can fail silently. Every uncaught exception is delivered to
  the handler.
- No child failure can cancel siblings without them knowing.

A coroutine that exits normally (returns) without setting state is also a
correctness issue. Every coroutine that manages lifecycle state must set a
terminal state before it returns in any code path.

### 6.3 No uncaught exception propagation to the process

The `CoroutineExceptionHandler` catches exceptions that would otherwise propagate
to the `Thread.UncaughtExceptionHandler` and terminate the process. A process
crash caused by an exception in a VPN service goroutine would:

1. Kill the foreground service with no `onDestroy`.
2. Leave the tun fd open in the kernel (the fd table is process-scoped).
3. Leave Android's VPN session active with no process routing packets.

The handler ensures the process stays alive, the service reaches `Stopped`, and
Android has the opportunity to call `onDestroy` and release the tun.

---

## 7. Future Extension Constraints

### 7.1 Config hot-reload

To reload the Mihomo config without restarting the VPN:

- Use `MihomoRepository` to call `PUT /configs` (full reload) or
  `PUT /providers/rules/:name` (rule provider only).
- Do **not** call `Veercore.start` again with a different config path.
  Calling `start` a second time with `coreRunning == true` is blocked by the
  mutex guard and is a logic error. Calling it after a stop-start cycle means
  the tun fd changes (new session, new fd number) — the Go runtime must be fully
  restarted to consume the new fd.
- AI rule injection (`AiController`) already uses this path correctly.

### 7.2 Reconnect / profile switch

A same-config user reconnect uses a retained service:

1. `ACTION_RECONNECT` → `requestReconnect` → `Stopping`.
2. `tearDownCore(finalizeState=false)` fully drains Mihomo and closes the old tun.
3. `bootCore` establishes a new tun and publishes `Starting → Running`.

A profile switch (changing subscription/config selection) uses the separate
retained-service transaction:

1. `ACTION_PREPARE_PROFILE_SWITCH` drains the old runtime and publishes `Stopped`.
2. Update/activate the validated config via `ProfileManager`.
3. `ACTION_START` reuses the retained service and reaches `Running`.

There is no in-place config swap. `Veercore.start` establishes the fd-to-config
binding at runtime start; it cannot be changed while running.

### 7.3 Multi-profile constraints

Android allows only one active `VpnService` per package. Attempting to establish
a second tun while one is active will either fail at `Builder.establish()` (which
returns `null` if the permission has been revoked by the competing profile) or
succeed by implicitly revoking the first session (triggering `onRevoke()` on the
first service). There is no supported path for running two Mihomo instances
concurrently in one process.

### 7.4 Android process death assumptions

`VeerVpnService` is declared with `START_STICKY`. After a process death, Android
will restart the service and deliver `onStartCommand(intent=null, …)`. The `null`
intent falls through to `else -> bootCore()` — the VPN re-establishes
automatically with the last config state on disk.

Assumptions that must hold for automatic recovery to succeed:

- `filesDir/mihomo/base.yaml` is valid. `ConfigManager.prepare` overwrites it
  from assets on each boot, so this holds unless the asset itself is invalid.
- `filesDir/mihomo/ai_override.yaml` is either valid YAML or absent. It is
  preserved across launches. A corrupt override file will cause `Veercore.start`
  to fail; the service will enter `Error` and require manual intervention.
- The VPN permission granted by the user persists across process death. Android
  does not re-prompt for the VPN permission unless it has been revoked.

After a watchdog-triggered stop (not a process death), the service will be
destroyed and will **not** automatically restart. `START_NOT_STICKY` is not used
here, but `START_STICKY` only re-delivers `null` after a *process kill* — not
after a normal `stopSelf()`. This is the correct behaviour: a watchdog stop
indicates a fault that should be surfaced to the user rather than silently
retried.

### 7.5 AI layer constraints

`AiController` interacts with the runtime exclusively through `MihomoRepository`.
It:

- May call `reloadAiProvider()`, `proxyGroups()`, and future REST operations.
- Must **not** read or write `MihomoEngine.state` for control-flow decisions
  (only for display/logging purposes, if at all).
- Must **not** hold a reference to `VeerVpnService`, `VeerLogger`, or the tun fd.
- Must assume that the REST API is unavailable if `MihomoRepository` returns
  failure results — it must not retry in a loop without backoff, as the core may
  be in the process of shutting down.
