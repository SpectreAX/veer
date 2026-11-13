# Veer Runtime Lifecycle Proposal

Cooperative runtime lifecycle design for the Veercore Go↔Android boundary.

**Status:** proposal — not yet implemented.  
**Supersedes:** the current `veer_core.go` API once accepted.  
**Resolves:** V1 (partial-init cleanup), V2 (unbounded start), UB1 (protector race),
RISK1 (log subscription leak), and the ready-signal gap identified in
`native_runtime_contract.md`.

---

## 1. Motivation

The current API (`Start`, `Stop`, `SetLogger`, `SetProtector` as package-level
functions) has four structural problems that cannot be fixed by patching the
Kotlin side alone:

| Problem | Root cause |
|---------|-----------|
| `Start` blocks the JNI thread indefinitely | `executor.ApplyConfig` runs synchronously on the calling goroutine with no cancellation path |
| No ready signal | Kotlin uses a fixed 15-second watchdog delay; the core may be ready in 2 s or not at all |
| Partial init leaves orphaned goroutines | `recover()` at `Start`'s entry frame catches the panic but does not drain goroutines that were launched before the panic site |
| Global mutable state | Package-level `protector`, `logger`, `logCancel` mean two concurrent init paths race silently |

The `startAttempted` flag (V1 fix) mitigates the orphaned-goroutine problem at
the Kotlin level, but does not prevent the goroutines from being created in the
first place. The right fix is a Go-side design that makes partial initialization
detectable and drainable regardless of which phase a panic fires in.

---

## 2. Design Principles

**P1 — Explicit ownership.**  
All runtime state belongs to one `Runtime` struct instance. No package-level
globals except the single-active-runtime guard (§13).

**P2 — Non-blocking start.**  
The JNI thread calling `Start` must be freed within O(microseconds). Long-running
initialization runs in a background goroutine. The JNI thread may then block on
`WaitReady(timeoutMs)` — a bounded, Go-side-timed wait — rather than on the
initialization itself.

**P3 — Bounded every operation.**  
Every method callable from JNI either returns in bounded time or accepts an
explicit timeout parameter that is enforced on the Go side (not the Kotlin side),
making it immune to the `withTimeoutOrNull`-cannot-cancel-JNI problem.

**P4 — Context-propagated cancellation.**  
`Start` creates an internal `context.Context`. All operations that can respect
cancellation use it. The context is not exposed at the JNI boundary; Kotlin
signals cancellation by calling `Cancel()`, which calls the stored cancel
function.

**P5 — Observable phases.**  
Runtime phase is an explicit integer enum readable from any thread without
acquiring a lock. Phase transitions are monotonic and unidirectional per
Runtime instance.

**P6 — Three-layer panic containment.**  
Every code path that touches Mihomo internals has a `defer recover()` at:
(a) the JNI frame entry, (b) the initialization goroutine entry, (c) the
shutdown goroutine entry. A panic at any layer transitions the runtime to
`Failed` without crashing the process.

**P7 — Single-use Runtime.**  
A `Runtime` is created, started (or not), and eventually stopped. It does not
restart. After reaching `Stopped`, the caller creates a new `Runtime`. This
makes phase transitions monotonic and eliminates the re-initialization
complexity.

**P8 — Explicit fd transfer.**  
`syscall.Dup` is called inside `Start`, before any goroutine is launched. After
`Start` returns, Go owns a dup of the fd and the original int32 is no longer
referenced by Go. The JVM-side `ParcelFileDescriptor` may be closed at any
time after `Start` returns.

---

## 3. Go API Surface

The following are the complete exported symbols. No implementation detail is
specified here; these are signatures and contracts only.

### 3.1 Phase enum

```go
// Phase represents the lifecycle stage of a Runtime instance.
// It is an int32 so it can be read atomically.
type Phase int32

const (
    PhaseCreated      Phase = 0  // NewRuntime() returned; Start not yet called
    PhaseInitializing Phase = 1  // Start() called; ApplyConfig in progress
    PhaseRunning      Phase = 2  // ApplyConfig succeeded; REST API reachable
    PhaseStopping     Phase = 3  // Stop() called; Shutdown in progress
    PhaseStopped      Phase = 4  // Shutdown completed or Cleanup() called
    PhaseFailed       Phase = 5  // unrecoverable error; Cleanup() required
)
```

Phase values are exposed as plain `int32` constants to avoid gomobile's
`const` mapping complexity. The Kotlin side maps them to a sealed interface
(`EngineState`) independently.

### 3.2 Runtime struct (exported, heap-allocated)

```go
type Runtime struct {
    // All fields unexported. Kotlin sees only the methods below.
}
```

gomobile generates a Java/Kotlin class `Runtime` with instance methods. The
struct is allocated on the Go heap; the JVM holds a reference via a
`go.Seq.Ref`. It is collected when both the JVM reference and all Go internal
references are dropped.

### 3.3 Constructor

```go
// NewRuntime allocates a Runtime in PhaseCreated.
// It does not register as the global active runtime — that happens in Start.
// Cheap: no goroutines, no file I/O, no network.
func NewRuntime() *Runtime
```

### 3.4 Configuration (must be called before Start)

```go
// SetLogger installs the Kotlin-side logger. Replaces any previous logger.
// Safe to call from any goroutine. No-op if runtime is not in PhaseCreated;
// the install-before-start ordering is enforced here rather than by the caller.
func (r *Runtime) SetLogger(l Logger)

// SetProtector installs the socket protector.
// Same ordering requirement and enforcement as SetLogger.
func (r *Runtime) SetProtector(p SocketProtector)
```

Moving these to instance methods eliminates the package-level globals and the
`SetProtector` data race (UB1 in `native_runtime_contract.md`). The ordering
constraint (both called before `Start`) is enforced by the Runtime checking
that it is still in `PhaseCreated`.

### 3.5 Startup

```go
// Start transitions the runtime from PhaseCreated to PhaseInitializing and
// launches the initialization goroutine. It returns in O(microseconds).
//
// The JNI thread is NOT blocked during initialization. Call WaitReady() to
// block the current goroutine until the runtime reaches PhaseRunning or
// PhaseFailed.
//
// Errors returned by Start itself (before the goroutine is launched):
//   - another runtime is already active (global singleton guard)
//   - runtime is not in PhaseCreated
//   - syscall.Dup(tunFd) failed
//   - configName is empty and default cannot be resolved
//
// The tunFd int32 is dup'd immediately inside Start. After Start returns,
// Go owns a dup of the fd; the caller may close the original at any time.
func (r *Runtime) Start(homeDir string, configName string, tunFd int32) error

// WaitReady blocks the calling goroutine until the runtime reaches PhaseRunning
// or a terminal phase (PhaseFailed, PhaseStopped), or until timeoutMs elapses.
//
// Returns true if and only if the runtime reached PhaseRunning before timeout.
// Returns false on timeout or if the runtime failed or was stopped during init.
//
// The timeout is enforced by a Go-side time.After — it is not subject to the
// Kotlin withTimeoutOrNull/JNI-non-cancellability problem.
//
// May be called multiple times; subsequent calls on a PhaseRunning runtime
// return true immediately (the ready channel is permanently closed).
func (r *Runtime) WaitReady(timeoutMs int64) bool

// Cancel signals the runtime's internal context to cancel. Has no effect if
// the runtime is not in PhaseInitializing. The initialization goroutine will
// detect the cancellation at its next context-check point and transition to
// PhaseFailed.
//
// Cancel does not block. It does not wait for the initialization goroutine to
// finish. Call WaitReady(timeout) or Cleanup() after Cancel to wait for
// the transition to PhaseFailed.
func (r *Runtime) Cancel()
```

### 3.6 Shutdown

```go
// Stop transitions a Running or Initializing runtime to PhaseStopping, cancels
// the internal context, and calls executor.Shutdown() in a shutdown goroutine.
// It blocks the calling goroutine until shutdown completes or timeoutMs elapses.
//
// Returns nil if the runtime reached PhaseStopped within the timeout.
// Returns a non-nil error if the timeout expired or if Shutdown panicked.
// On timeout, the runtime transitions to PhaseFailed (Shutdown is still
// running in a goroutine; the fd dup is not closed until that goroutine exits
// or the process dies).
//
// Stop is safe to call from PhaseInitializing: it cancels initialization
// and waits for the init goroutine to drain before calling Shutdown.
// Stop is a no-op if the runtime is already in PhaseStopped or PhaseFailed;
// it returns nil in both cases.
func (r *Runtime) Stop(timeoutMs int64) error
```

### 3.7 Recovery

```go
// Cleanup is the deterministic recovery path after PhaseFailed.
// It attempts executor.Shutdown() (with panic recovery), closes the fd dup
// if still open, unregisters the runtime from the global singleton guard,
// and transitions the runtime to PhaseStopped.
//
// Cleanup is safe to call regardless of the current phase:
//   PhaseFailed       → performs cleanup, transitions to PhaseStopped
//   PhaseStopped      → no-op, returns nil
//   PhaseRunning      → equivalent to Stop(5000) followed by Cleanup
//   PhaseCreated      → no-op (nothing to clean up)
//   PhaseInitializing → equivalent to Cancel + Wait(5000) + Cleanup
//
// After Cleanup returns, the caller may safely create a new Runtime.
func (r *Runtime) Cleanup() error
```

### 3.8 Observation

```go
// Phase returns the current lifecycle phase as an int32.
// Safe to call from any goroutine; reads an atomic value.
func (r *Runtime) Phase() int32

// LastError returns the string representation of the last error or panic
// that caused the runtime to enter PhaseFailed, or "" if none.
// Safe to call from any goroutine; reads under a lightweight lock.
func (r *Runtime) LastError() string

// Version returns the build identifier for compatibility checks.
func Version() string  // package-level, as now
```

---

## 4. Phase State Machine

### 4.1 Diagram

```
                          ┌─────────────────────────────────────────────┐
                          │                    CREATED                   │
                          │  NewRuntime() returned; no goroutines        │
                          └────────────────────┬────────────────────────┘
                                               │ Start() ok
                                               ▼
                          ┌─────────────────────────────────────────────┐
                     ┌───►│                 INITIALIZING                 │
                     │    │  init goroutine running; ctx active          │◄──┐
                     │    └──────────┬──────────────────┬───────────────┘   │
                     │               │ ApplyConfig ok    │ ApplyConfig err   │
                     │               │ REST API bound    │ or panic          │
                     │               ▼                   ▼                   │
                     │  ┌────────────────────┐  ┌───────────────────────┐   │
Stop() while init ───┤  │      RUNNING       │  │       FAILED          │   │
                     │  │  core healthy      │  │  lastErr set          │   │
                     │  └─────────┬──────────┘  └─────────┬─────────────┘   │
                     │            │ Stop(t)                │ Cleanup()       │
                     │            ▼                        ▼                 │
                     │  ┌─────────────────────────────────────────────┐     │
                     │  │                  STOPPING                   │     │
                     │  │  Shutdown goroutine running; ctx cancelled  │     │
                     │  └──────────────────┬──────────────────────────┘     │
                     │                     │ Shutdown ok        ┌───────────┘
                     │                     │                    │ Stop timeout fires
                     │                     ▼                    │ (→ FAILED, then
                     │  ┌───────────────────────────────────┐   │  Cleanup → here)
                     └──┤            STOPPED                │◄──┘
                        │  terminal; create new Runtime     │
                        └───────────────────────────────────┘
```

### 4.2 Transition table

| From | To | Trigger | Condition |
|------|----|---------|-----------|
| `Created` | `Initializing` | `Start()` | Global singleton CAS succeeds; `syscall.Dup` ok |
| `Created` | `Created` | `Start()` fails | Global guard held by another runtime; or Dup fails |
| `Initializing` | `Running` | init goroutine | `executor.ApplyConfig` returns nil; REST listener bound |
| `Initializing` | `Failed` | init goroutine | `ApplyConfig` returns error or panic recovered |
| `Initializing` | `Failed` | `Cancel()` | Context cancelled; init goroutine detects and exits |
| `Initializing` | `Stopping` | `Stop()` | Context cancelled; waits for init goroutine to drain |
| `Running` | `Stopping` | `Stop()` | Context cancelled; shutdown goroutine launched |
| `Stopping` | `Stopped` | shutdown goroutine | `executor.Shutdown()` returns (nil or error absorbed) |
| `Stopping` | `Failed` | shutdown goroutine | `Shutdown()` panics and recovery cannot complete it |
| `Stopping` | `Failed` | `Stop()` timeout | Shutdown goroutine still running; timeout fires |
| `Failed` | `Stopped` | `Cleanup()` | Best-effort Shutdown + fd close + global unregister |
| `Stopped` | — | any | Terminal. Calls are no-ops or return nil. |

### 4.3 Monotonicity

Phase values are monotonically non-decreasing per instance in the normal path
(`Created=0 → Initializing=1 → Running=2 → Stopping=3 → Stopped=4`).
`Failed=5` is a lateral exit from any non-terminal phase; `Cleanup` moves
`Failed→Stopped`. No transition moves to a lower-numbered phase within a single
Runtime instance. This monotonicity makes reading the phase atomic (int32
load) safe without synchronization.

---

## 5. Goroutine Architecture

### 5.1 Goroutine inventory

| Name | Launched by | Exits when | Panic protection |
|------|-------------|------------|------------------|
| `initGoroutine` | `Start()` | ApplyConfig returns (ok or error); ctx cancelled; recovered panic | `defer recover()` at top of goroutine; transitions to Failed |
| `shutdownGoroutine` | `Stop()` or `Cleanup()` | `executor.Shutdown()` returns or panics | `defer recover()` at top; transitions to Failed or Stopped |
| `logForwarder` | `SetLogger` (non-nil) | `r.done` closed; log subscription channel closed | `deliver()` has its own `recover()` |
| Mihomo internal goroutines | `executor.ApplyConfig` | `executor.Shutdown()` | Mihomo's own recover (unknown coverage); process crash on escape |

### 5.2 Coordination channels (on Runtime struct)

```
ready    chan struct{}   closed exactly once, when phase leaves Initializing
                        (either Running or Failed). Never sent to — only closed.
                        Multiple WaitReady() calls select on it safely.

done     chan struct{}   closed when phase reaches Stopped or Failed+Cleanup done.
                        Used by Stop() to wait for the shutdown goroutine.

stopReq  chan struct{}   capacity 1. Stop() sends to it once. The shutdown goroutine
                        reads it. Prevents double-launch of shutdownGoroutine.

ctx      context.Context   created in Start(), cancelled by Cancel() and Stop().
cancel   context.CancelFunc  stored on struct, called by Cancel() and Stop().
```

### 5.3 initGoroutine outline

```
func (r *Runtime) initGoroutine(cfg *config.Config) {
    defer func() {
        if p := recover(); p != nil {
            r.setFailed(fmt.Errorf("init panic: %v", p))
            close(r.ready)  // unblocks WaitReady callers
        }
    }()

    // All calls that can be context-aware use r.ctx.
    // executor.ApplyConfig does not yet accept a context; treat it as
    // an atomic operation here; future Mihomo versions may add ctx support.
    if err := applyWithContextCheck(r.ctx, cfg); err != nil {
        r.setFailed(err)
        close(r.ready)
        return
    }

    // Subscribe to log events now that Mihomo is running.
    r.startLogForwarder()

    r.setPhase(PhaseRunning)
    close(r.ready)  // signals WaitReady() callers
}
```

`applyWithContextCheck` runs `executor.ApplyConfig(cfg, true)` and, on return,
checks `r.ctx.Err()`. If the context was cancelled during `ApplyConfig` (which
doesn't check it internally), the function calls `executor.Shutdown()` and
returns a cancellation error. This is not a true cooperative cancel of
`ApplyConfig` — the work runs to completion — but it ensures the runtime does
not enter `PhaseRunning` after a `Cancel()` call.

### 5.4 shutdownGoroutine outline

```
func (r *Runtime) shutdownGoroutine() {
    defer func() {
        if p := recover(); p != nil {
            r.setFailed(fmt.Errorf("shutdown panic: %v", p))
        } else {
            r.setPhase(PhaseStopped)
        }
        r.closeFdDup()
        r.unregisterGlobal()
        close(r.done)
    }()

    r.stopLogForwarder()
    executor.Shutdown()
}
```

`close(r.done)` is deferred last so `Stop()`'s select always fires after
the phase transition and fd close are complete.

---

## 6. Panic Containment Strategy

### Layer 1 — JNI frame entry (existing)

Every exported method on `Runtime` that calls into Mihomo has:

```go
func (r *Runtime) SomeMethod(...) (err error) {
    defer func() {
        if p := recover(); p != nil {
            err = fmt.Errorf("someMethod panic: %v", p)
        }
    }()
    // ...
}
```

This catches panics that occur synchronously on the JNI goroutine (e.g., inside
`syscall.Dup`, inside channel operations in `Cancel`).

### Layer 2 — Initialization goroutine (new)

`initGoroutine` has its own `defer recover()`. A panic in `executor.ApplyConfig`
or anywhere in the initialization sequence is caught here, `lastErr` is set,
phase transitions to `Failed`, and `ready` is closed. The JNI thread is never
involved.

This is the key fix for partial initialization: the panic does not escape to the
Go runtime's top-level handler, and the init goroutine exits cleanly, allowing
`Cleanup()` to drain remaining Mihomo goroutines.

### Layer 3 — Shutdown goroutine (new)

`shutdownGoroutine` has its own `defer recover()`. A panic in
`executor.Shutdown()` transitions to `Failed` rather than crashing the process.
`closeFdDup()` and `unregisterGlobal()` are deferred after the recover so the
global singleton guard is always released.

### Layer 4 — Mihomo internal goroutines (aspirational)

Panics in Mihomo's own goroutines (inbound tun reader, health check timers,
proxy connection goroutines) are not caught by any of the above layers. These
require Mihomo itself to use `defer recover()` in its goroutines, which is a
Mihomo upstream concern. The watchdog provides detection (the REST API becomes
unreachable) but not prevention.

A future mitigation: use `runtime.SetPanicOnFault(true)` combined with a signal
handler, or intercept SIGABRT. This is platform-specific and out of scope for
this proposal.

---

## 7. Fd Ownership Protocol

### 7.1 Transfer sequence

```
JVM creates tunFd via VpnService.Builder.establish()
  │
  ├─ JVM calls runtime.Start(homeDir, config, tunFd.fd)
  │    ├─ Go calls syscall.Dup(int(tunFd)) → dupFd; stores dupFd on Runtime struct
  │    └─ Start returns. Go now owns dupFd. Original tunFd int32 not stored.
  │
  ├─ JVM may close tunFd (pfd.close()) at any time after Start returns.
  │    └─ Kernel decrements refcount. Go's dupFd still valid.
  │
  └─ shutdownGoroutine calls r.closeFdDup()
       └─ syscall.Close(r.fdDup); r.fdDup = -1
            └─ Kernel decrements refcount. If JVM already closed its copy,
               the kernel file (tun device) is fully reclaimed here.
```

### 7.2 Who may close the dup

Only `shutdownGoroutine` via `r.closeFdDup()`. This function is idempotent
(`r.fdDup == -1` guard) and is called exactly once per Runtime lifecycle
(deferred in `shutdownGoroutine`). Cleanup() also calls it via the shutdown path.

No other code path calls `syscall.Close(r.fdDup)`. In particular:
- `Cancel()` does NOT close the dup; it only signals the context.
- `initGoroutine` failure does NOT close the dup; Cleanup() calls Stop-equivalent.
- Layer 1 / JNI frame recoveries do NOT close the dup.

### 7.3 Handling Start() followed immediately by Cancel()

If `Cancel()` fires while `initGoroutine` is executing `executor.ApplyConfig`:
1. `r.ctx` is cancelled.
2. `applyWithContextCheck` detects cancellation after `ApplyConfig` returns.
3. It calls `executor.Shutdown()` (drains partially-started goroutines).
4. `initGoroutine` sets `Failed`, closes `ready`.
5. `Cleanup()` is called by the Kotlin side.
6. `shutdownGoroutine` runs (as part of Cleanup), calls `closeFdDup()`.

The fd dup is closed even in the Cancel-during-init scenario. No leak.

---

## 8. Startup Protocol (Two-Phase)

The two-phase startup replaces the current single blocking `Veercore.start()` call.

### 8.1 Phase A — Initiate (non-blocking)

```kotlin
// VeerVpnService.bootCore() — inside engineMutex

val runtime = Runtime()
runtime.setLogger(VeerLogger(File(filesDir, "logs")))
runtime.setProtector(protector)

// Start returns in O(microseconds). The init goroutine is now running.
val startErr = runCatching { runtime.start(homeDir, BASE_CONFIG, pfd.fd) }.exceptionOrNull()
if (startErr != null) {
    // Pre-goroutine failure: Dup failed, singleton guard held, etc.
    MihomoEngine.setState(EngineState.Error(startErr.message ?: "start failed"))
    tearDownTun(); stopSelf(); return
}
// pfd may be closed here; Go holds the dup. We keep it open for now
// for symmetry with tearDownTun (which closes it in tearDownCore).
MihomoEngine.setState(EngineState.Starting)
```

### 8.2 Phase B — Wait for ready (bounded)

```kotlin
// Still inside bootCore(), after Start() returns

val ready = runtime.waitReady(START_READY_TIMEOUT_MS)  // e.g. 20_000L
if (!ready) {
    // Timeout or failed. Check phase for diagnostics.
    val msg = when (runtime.phase()) {
        Runtime.PHASE_FAILED  -> runtime.lastError().ifBlank { "init failed" }
        else                  -> "start timed out after ${START_READY_TIMEOUT_MS}ms"
    }
    MihomoEngine.publishLifecycleLog("runtime not ready: $msg")
    MihomoEngine.setState(EngineState.Error(msg))
    runCatching { runtime.cleanup() }  // drain partial init, release singleton
    tearDownTun(); stopSelf(); return
}

this.runtime = runtime          // store reference on VeerVpnService
coreRunning = true
MihomoEngine.setState(EngineState.Running)
launchWatchdog()
```

`WaitReady` is a blocking JNI call, but its timeout is enforced by Go's
`time.After`. When `timeoutMs` elapses, Go returns `false` and the JNI thread
is freed — regardless of what `initGoroutine` is doing. This is the resolution
of V2: the start timeout is genuinely bounded, not subject to the
`withTimeoutOrNull`/non-cancellable-JNI limitation.

### 8.3 Why this is better than the current approach

| | Current | Proposed |
|---|---|---|
| JNI thread blocked during ApplyConfig | Yes (unbounded) | No (Start returns in µs) |
| Start timeout effective | No (withTimeoutOrNull useless for JNI) | Yes (Go-side time.After) |
| Ready signal | Fixed 15s watchdog delay | Exact: WaitReady returns when REST API is bound |
| Partial init cleanup | startAttempted flag (Kotlin side) | Go-side defer in initGoroutine |
| Protector data race | Yes (package global, no mutex) | No (instance field, set before Start) |

---

## 9. Shutdown Protocol

```kotlin
// VeerVpnService.tearDownCore() — inside engineMutex

if (this.runtime != null) {
    // Stop() blocks the IO thread, but is bounded by Go's time.After.
    // No withTimeoutOrNull wrapper needed; the timeout is inside Stop().
    runCatching { this.runtime!!.stop(STOP_TIMEOUT_MS) }
        .onFailure { MihomoEngine.publishLifecycleLog("stop error: ${it.message}") }
    // After Stop() returns, the fd dup is closed by shutdownGoroutine.
    // tearDownTun() closes the JVM-side pfd.
    this.runtime = null
}
tearDownTun()
MihomoEngine.setState(EngineState.Stopped)
```

The `Stop(timeoutMs)` call replaces the current `withTimeoutOrNull(6_000)` wrapper.
The 6-second semantic is preserved but enforced inside Go rather than Kotlin.

On Stop timeout:
1. Go transitions runtime to `PhaseFailed` (not `PhaseStopped`).
2. `shutdownGoroutine` continues running in the background.
3. Go's `Stop()` returns a timeout error.
4. Kotlin logs the error, calls `tearDownTun()`, sets `Stopped` state.
5. When `shutdownGoroutine` eventually completes, it calls `closeFdDup()` and
   `unregisterGlobal()`. The singleton guard is released even on timeout.

---

## 10. Recovery Protocol (After Failed)

After any `PhaseFailed` transition, the Kotlin side calls:

```kotlin
runCatching { runtime.cleanup() }
```

`Cleanup()` on the Go side:
1. Cancels `r.ctx` (if not already cancelled).
2. Waits for `initGoroutine` to exit (if still running), with a 5-second internal timeout.
3. Calls `executor.Shutdown()` (with `defer recover()`).
4. Calls `r.closeFdDup()`.
5. Calls `r.unregisterGlobal()` — releases the singleton CAS.
6. Transitions to `PhaseStopped`.
7. Returns.

After `Cleanup()` returns:
- The Go singleton guard is released.
- The fd dup is closed.
- A new `Runtime` may be created immediately.

The Kotlin side may then attempt a restart:

```kotlin
// After Cleanup() — safe to start a new Runtime
if (shouldRetry) {
    serviceScope.launch { bootCore() }  // creates a new Runtime internally
}
```

---

## 11. Kotlin Integration Model

### 11.1 VeerVpnService field changes

```kotlin
// Add:
private var runtime: Runtime? = null  // null when not started; set in bootCore
```

The `coreRunning: Boolean` and `startAttempted: Boolean` flags become redundant
(phase tracking moves to Go) but may be kept as a Kotlin-side performance
optimization to avoid JNI calls for the `coreRunning` guard in `bootCore`.

### 11.2 Complete bootCore sketch

```
engineMutex.withLock {
    if (coreRunning) { log("already running"); return }
    setState(Starting)

    runtime = Runtime()
    runtime.setLogger(VeerLogger(logDir))
    runtime.setProtector(...)

    val pfd = Builder()...establish() ?: { setState(Error); tearDownTun; stopSelf; return }
    tunInterface = pfd

    val startErr = start(runtime, pfd.fd)  // ~microseconds
    if (startErr) { setState(Error); cleanup(runtime); tearDownTun; stopSelf; return }

    val ready = runtime.waitReady(START_READY_TIMEOUT_MS)  // blocks IO thread, bounded
    if (!ready) { setState(Error(runtime.lastError)); cleanup(runtime); tearDownTun; stopSelf; return }

    coreRunning = true; setState(Running); launchWatchdog()
}
```

### 11.3 Complete tearDownCore sketch

```
engineMutex.withLock {
    if (runtime != null) {
        runtime.stop(STOP_TIMEOUT_MS)   // blocking, bounded by Go timer
        runtime = null
    }
    tearDownTun()
    setState(Stopped)
}
```

The `startAttempted` flag and the `runBlocking { withTimeoutOrNull ... }` pattern
in `onDestroy` are both replaced by the bounded `Stop(timeoutMs)` call.

---

## 12. Android–Go Lifecycle Handshake

The ready signal closes the gap between "Start() returned" and "REST API
is actually reachable" — which is currently approximated by the 15-second
watchdog initial delay.

### 12.1 What triggers the ready signal

Inside `initGoroutine`, after `executor.ApplyConfig` returns successfully, the
runtime should verify that the REST API listener is actually bound before
closing `r.ready`. This can be done with a short retry loop:

```go
// In initGoroutine, after ApplyConfig returns nil:
if !waitForRestApi(r.ctx, "127.0.0.1:9090", 5*time.Second) {
    r.setFailed(errors.New("REST API did not bind within 5s"))
    close(r.ready)
    return
}
r.setPhase(PhaseRunning)
close(r.ready)
```

`waitForRestApi` dials `127.0.0.1:9090` with short retries. This provides a
direct, accurate signal rather than a fixed delay.

### 12.2 Watchdog simplification

With an accurate ready signal, the watchdog's 15-second initial delay can be
reduced to 5 seconds (enough to allow the REST API to warm up before the first
health probe, even if `WaitReady` already verified it once).

### 12.3 State consistency

The Android `EngineState.Running` is set ONLY after `WaitReady` returns true,
which requires `PhaseRunning` in Go, which requires the REST API to be reachable.
There is no window where the Kotlin state says Running but the REST API is down
(unlike the current approach where Running is set after `Veercore.start()` returns
but the REST API may not yet be bound).

---

## 13. Single-Runtime Invariant

### 13.1 Go-side enforcement

```go
// Package-level; protects against two Runtime instances calling Start concurrently.
var globalActive atomic.Pointer[Runtime]

// In Runtime.Start():
if !globalActive.CompareAndSwap(nil, r) {
    return errors.New("veercore: another runtime is active; call Cleanup() first")
}
// On Stopped or Failed+Cleanup: globalActive.CompareAndSwap(r, nil)
```

`atomic.Pointer` (available since Go 1.19) provides lock-free CAS semantics.
The Kotlin `engineMutex` remains as a second, independent guard at the service
layer. Two independent guards at different abstraction levels means a bug in
either layer cannot produce two live runtimes.

### 13.2 Kotlin-side guard (retained)

`engineMutex` in `VeerVpnService` serializes `bootCore` and `tearDownCore`
calls. This is not redundant with the Go-side CAS: it also serializes the
Kotlin-side state machine transitions (`EngineState`) and the tun fd lifecycle
(`tunInterface`), which are not visible to Go.

### 13.3 What happens on CAS failure

If `Start()` returns the "another runtime is active" error:
- The caller logs it.
- The new `Runtime` object (allocated but not started) transitions to... 
  `Created` still. It was never registered. Just discard it.
- No cleanup needed; the object will be GC'd.
- The Kotlin side should check its own `engineMutex` invariant: if the CAS
  fails, there is likely a bug (the Kotlin mutex should have prevented a
  double-start). Log and raise an error state.

---

## 14. gomobile Compatibility Notes

### 14.1 Types that cross the JNI boundary cleanly

| Go type | Java/Kotlin type | Notes |
|---------|-----------------|-------|
| `*Runtime` | `Runtime` (object ref) | Heap-allocated, GC-managed |
| `string` | `String` | Immutable copy |
| `int32` | `int` | Direct mapping |
| `int64` | `long` | Direct mapping |
| `bool` | `boolean` | Direct mapping |
| `error` (return) | `Exception` (thrown) | gomobile maps non-nil error to throw |
| `Logger` (interface) | Kotlin class implementing `Logger` | gomobile generates JNI glue |
| `SocketProtector` (interface) | Kotlin anonymous class | Same as Logger |

### 14.2 Types that do NOT cross cleanly

| Go type | Issue |
|---------|-------|
| `context.Context` | Can be passed through gomobile but requires the Kotlin side to construct Go context objects via `golang.org/x/mobile/bind`. Avoided in this design. |
| `chan T` | Not supported. Coordination uses method calls instead of channels. |
| `func()` (callback) | Not directly supported. Use interface with single method instead. |
| `sync.WaitGroup`, `sync.Mutex` | Not exposed. Internal to Go. |

### 14.3 Phase as int32

`Phase` is an alias of `int32` rather than a named type with a gomobile-friendly
constant set. gomobile's constant mapping for custom types is fragile across SDK
versions. Int32 constants with a naming convention (e.g.
`Veercore.PHASE_RUNNING = 2`) are more reliable.

### 14.4 Nil interface handling

gomobile maps a Go `nil` interface value to a Java `null`. `SetLogger(nil)` and
`SetProtector(nil)` must handle null input — current code already does this via
the nil guards in `SetLogger`. The new struct methods must do the same.

---

## 15. Deficiencies Resolved by This Proposal

| ID | Description | Resolution |
|----|-------------|------------|
| V1 | Partial init not cleaned up after failed Start | `initGoroutine` has own `defer recover()`; transitions to `Failed`; `Cleanup()` drains via `Shutdown()`. No `startAttempted` flag needed. |
| V2 | Start has no effective timeout | `WaitReady(timeoutMs)` is a genuinely bounded JNI call (Go-side `time.After`). The JNI thread is freed immediately after `Start()`; it is only blocked during `WaitReady`, which always returns within `timeoutMs`. |
| UB1 | `SetProtector` data race | `SetProtector` is an instance method called before `Start`. No concurrent read is possible (runtime is in `Created`, no goroutines running). No mutex needed for the set; read under mutex in the protector-use path. |
| RISK1 | Log subscription not unsubscribed | Log forwarder is now owned by the Runtime instance. `stopLogForwarder()` in `shutdownGoroutine` explicitly unsubscribes before `executor.Shutdown()`. |
| GAP | No ready signal; 15-second fixed delay | `WaitReady` blocks until `ready` channel is closed, which happens after the REST API is verified reachable. |

---

## 16. Open Questions

**Q1: Does `executor.ApplyConfig` respect `context.Context` in the Mihomo version
we pin (`v1.18.10`)?**  
If not, `Cancel()` during `Initializing` does not interrupt `ApplyConfig`. It
only prevents the runtime from entering `PhaseRunning` after `ApplyConfig`
returns. This is acceptable: `WaitReady(timeout)` returns false; `Cleanup()`
drains goroutines. True cooperative cancellation requires a Mihomo API change
(passing `ctx` through to the apply/parse pipeline). Track as a future
Mihomo upstream request.

**Q2: What is the behaviour of `executor.Shutdown()` on partially-initialized
state?**  
Specifically: if `ApplyConfig` starts the inbound tun goroutine but panics before
starting the REST API, does `Shutdown()` correctly tear down the tun goroutine?
This must be verified empirically. If `Shutdown()` panics on partial state,
the Layer 3 panic recovery in `shutdownGoroutine` will catch it and transition
to `Failed`, after which `Cleanup()` closes the fd dup via `closeFdDup()`.
The tun goroutine may be leaked, but the fd dup will be closed, so the kernel
tun device is eventually reclaimed.

**Q3: Should `Runtime.Phase()` be gated by a mutex or remain an atomic read?**  
The atomic read is slightly stale (reads a cached value without memory barrier)
but sufficient for the Kotlin side's purpose (logging and UI state display).
`WaitReady` and `Stop` use channel-based synchronization which provides the
necessary happens-before guarantees. Use `atomic.LoadInt32` for `Phase()`.

**Q4: How should the watchdog interact with `Runtime.Phase()`?**  
The watchdog currently probes the REST API via HTTP. With the Runtime struct, it
could additionally read `runtime.phase()` to distinguish between a truly dead
core (PhaseFailed) and a temporarily busy core (PhaseRunning but API slow).
Consider transitioning the watchdog to check `runtime.phase() == PhaseRunning`
as a fast pre-check before making the HTTP call.
