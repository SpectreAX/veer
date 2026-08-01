# Veercore Runtime: Non-Recoverable States Analysis

**Scope:** Identifies scenarios where the Veercore runtime (present architecture + cooperative
lifecycle proposal) may become unrecoverable without process death. For each scenario: whether
in-process cleanup is possible, whether a subsequent restart is safe, whether process restart
is required, whether the global singleton CAS can be safely released, and the split-brain risk.

**Companion documents:**
- `native_runtime_contract.md` — JNI boundary invariants
- `runtime_lifecycle_proposal.md` — cooperative lifecycle API (Runtime struct)
- `runtime_invariants.md` — Android-side service invariants

---

## Terminology

**Split-brain:** Two goroutines simultaneously accessing Mihomo's global `executor` package state
(`executor.ApplyConfig`, `executor.Shutdown`, or any Mihomo subsystem that reads global proxy
tables). Symptoms range from wrong routing to panic storms from deep inside Mihomo goroutines.

**Zombie goroutine:** A goroutine that is permanently blocked (in a syscall, JNI call, or
channel receive on a channel that will never be written to again) and cannot be killed by any
Go mechanism. It holds whatever resources it acquired before blocking.

**CAS:** The `globalActive atomic.Pointer[Runtime]` compare-and-swap singleton in the lifecycle
proposal. Releasing it (`globalActive.CompareAndSwap(r, nil)`) is the gate that allows a new
Runtime to be created.

**Force-release path:** Code that runs independently of all goroutines — either in `Cleanup()`'s
timeout handler or before `Cleanup()` returns — that unconditionally clears the CAS and closes
any remaining fd dups, regardless of whether `shutdownGoroutine` has completed.

---

## Scenario 1: Hung `ApplyConfig` goroutine

### Description

`executor.ApplyConfig(cfg, true)` is called inside `initGoroutine`. It spawns Mihomo's internal
subsystem goroutines (DNS, rule engine, proxy listeners, etc.) and blocks until they are all
responsive. If any subsystem blocks indefinitely (network interface not ready, OS resource
exhausted, MMDB download routing through the tun it is trying to bring up), `ApplyConfig` never
returns.

Geo databases are now bundled in the APK and verified before config validation. Startup fails
before establishing TUN when `geoip.metadb` is unavailable, so imported `dns.fallback:` policies
can safely use the local GeoIP filter without triggering an MMDB-via-tun download. Other hang
paths remain: kernel socket operations during listener bind, file descriptor exhaustion, or
future config changes that introduce another blocking subsystem.

### State after hang

| Resource | State |
|---|---|
| `initGoroutine` | Permanently blocked inside `ApplyConfig` |
| Phase | Stuck at `Initializing` (1) — never reaches `Running` (2) |
| Mihomo global executor | Partially initialized; indeterminate lock state |
| Tun fd dup | Held by the goroutine that called `ApplyConfig` |
| `globalActive` CAS | Holds a pointer to this Runtime — blocks any new Runtime |
| Android-side | `WaitReady(timeoutMs)` returns `false`; Kotlin calls `Cancel()` |

### Recovery analysis

**`Cancel()` → `Stop(timeoutMs)`:** Signals `stopReq` channel. `shutdownGoroutine` wakes and
calls `executor.Shutdown()`. This is the only chance at in-process recovery.

**`executor.Shutdown()` on partially-initialized state:** Documented as undefined behavior in
`native_runtime_contract.md` §10 and the proposal's open question Q2. Mihomo provides no
documented guarantee that `Shutdown()` is safe when `ApplyConfig` has not completed. In
practice it may: (a) race with internal subsystem goroutines being initialized concurrently,
(b) deadlock on an internal mutex held by a subsystem that `ApplyConfig` is waiting for, or
(c) work correctly if the specific subsystem that blocked has not yet acquired internal locks.

**If `executor.Shutdown()` itself blocks:** See Scenario 2. Both goroutines (`initGoroutine`
and `shutdownGoroutine`) are now permanently blocked. Full split-brain, no recovery.

**If `executor.Shutdown()` succeeds:** `initGoroutine` remains zombie — it is blocked inside
`ApplyConfig` which is now racing with the completed `Shutdown`. Eventually `ApplyConfig` may
return (with an error or panic) or remain blocked forever. Either way, the Phase transitions
to `Stopping` → `Stopped`, `closeFdDup()` runs in `shutdownGoroutine`'s defer, and the CAS
is released. A new Runtime can be created, but the zombie `initGoroutine` persists in the
process, and if it ever returns from `ApplyConfig` it will attempt to access Mihomo global
state while a new `ApplyConfig` may be running.

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **Conditional** — only if `executor.Shutdown()` returns promptly on partially-initialized state |
| Restart safe after recovery? | **Conditional** — zombie initGoroutine is an ongoing split-brain risk |
| Process restart required? | **Required** if `executor.Shutdown()` blocks, or if zombie goroutine returns post-restart |
| CAS safely releasable? | **Only** via force-release path in `Cleanup()` timeout handler |
| Split-brain risk? | **High** — zombie goroutine may resume inside `executor` after new Runtime starts |

### Required design invariant

`Cleanup()`'s timeout handler must contain a force-release path that: (1) calls
`closeFdDup()` unconditionally, (2) releases the CAS unconditionally. This is the only
safe mechanism when `shutdownGoroutine` itself is blocked.

---

## Scenario 2: Deadlocked `executor.Shutdown`

### Description

`executor.Shutdown()` is called from `shutdownGoroutine`. Inside Mihomo, `Shutdown` tears
down the DNS server, proxy listeners, connection pools, and the rule engine. Each subsystem
teardown acquires its own internal mutex and sends to channels. If any subsystem goroutine
is permanently blocked (e.g., waiting on a DNS resolution that routes back through the tun),
`Shutdown` blocks forever waiting for that goroutine to drain.

This is structurally similar to Scenario 1 but affects the shutdown path, which makes it
more dangerous: cleanup resources (fd dup, CAS) that live in `shutdownGoroutine`'s defer
block are never reached.

### State after hang

| Resource | State |
|---|---|
| `shutdownGoroutine` | Permanently blocked inside `executor.Shutdown()` |
| Phase | Stuck at `Stopping` (3) — never reaches `Stopped` (4) |
| `closeFdDup()` | Never called (it is after the blocking call in the defer chain) |
| `unregisterGlobal()` / CAS | Never released |
| `globalActive` CAS | Holds a pointer to this Runtime indefinitely |
| Android tun fd dup | Held by Go — kernel fd refcount not fully released |
| `Stop(timeoutMs)` | Returns with `ErrStopTimeout` |
| `Cleanup()` | Called; timeout fires; force-release path runs (if implemented) |

### Recovery analysis

**Without force-release path:** `Cleanup()` returns and the Kotlin side considers the Runtime
done, but the CAS still holds a pointer to this Runtime. `NewRuntime()` → `Start()` calls
`globalActive.CompareAndSwap(nil, r)` and fails. No new Runtime can ever be created in this
process. The existing fd dup is held by the blocked goroutine. Even if Android closes the
`ParcelFileDescriptor`, the kernel refcount is not zero.

**With force-release path (required by design):**
```go
// In Cleanup(), after Stop() returns ErrStopTimeout:
r.closeFdDupOnce.Do(func() { syscall.Close(r.fdDup) })
globalActive.CompareAndSwap(r, nil)
```
This allows a new Runtime to be created. However, `shutdownGoroutine` remains blocked inside
`executor.Shutdown()`. When the new Runtime calls `executor.ApplyConfig()`, both calls are
operating on Mihomo's global state simultaneously. This is a split-brain condition. The new
Runtime may function, fail with panics, or corrupt proxy routing silently.

**Process restart:** The only way to terminate the deadlocked `executor.Shutdown()` goroutine.

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **No** — the deadlock is in the only cleanup path |
| Restart safe after CAS release? | **No** — split-brain with blocked goroutine still in executor.Shutdown |
| Process restart required? | **Yes, always** |
| CAS safely releasable? | **Force-release path can release it** but restart is still unsafe |
| Split-brain risk? | **Critical** — concurrent ApplyConfig + blocked Shutdown |

### Structural implication

Scenario 2 is the principal argument against attempting in-process restart after any
shutdown-path failure. The force-release path is necessary to avoid the CAS being
permanently held, but CAS release alone does not make in-process restart safe.

---

## Scenario 3: Leaked goroutines holding global Mihomo state

### Description

`executor.ApplyConfig(cfg, true)` successfully initializes Mihomo but spawns internal goroutines
that hold references to Mihomo's global proxy tables, rule engine, and DNS cache. When
`executor.Shutdown()` is called, it sends termination signals to these goroutines via channels.
If a goroutine has a bug that causes it to ignore or delay draining its termination channel
(e.g., it is blocked in a long DNS lookup or connection attempt), `Shutdown()` may return before
the goroutine has actually released its reference.

This is distinct from Scenario 2: `Shutdown()` returns successfully, but leaked goroutines
continue running.

### State after "successful" shutdown

| Resource | State |
|---|---|
| `shutdownGoroutine` | Completes normally |
| Phase | Transitions correctly to `Stopped` (4) |
| `closeFdDup()` | Called — fd dup closed at kernel level |
| CAS | Released — new Runtime can be created |
| Leaked goroutines | Still running; hold references to old Mihomo proxy tables |
| New `ApplyConfig` | Reinitializes global proxy tables; old references now point to stale data |

### Recovery analysis

**The leak is silent.** `Shutdown()` returns success. Phase reaches `Stopped`. `Cleanup()`
returns no error. Android side proceeds with a new Runtime normally.

**The corruption is deferred.** When the new `ApplyConfig` reinitializes Mihomo's global
proxy tables, the leaked goroutines hold stale pointers. Depending on Mihomo's internal
memory model, they may: (a) access freed memory (Go's GC prevents dangling pointers, so
this is a stale-reference problem, not a use-after-free), (b) route traffic through the
old proxy configuration, or (c) write into the old proxy table structures while the new
ApplyConfig writes different values.

**Observable symptoms:** Wrong proxy selection for traffic (e.g., traffic routed through
old proxy group after reconfiguration), rule-engine mismatches, or anomalous log lines from
Mihomo's proxy selector. The race detector would flag data races.

**Mihomo's actual behavior:** Depends on whether Mihomo uses pointer replacement (GC-safe,
no race) or in-place mutation (racy). This is an open question (Q2 in the proposal). Without
reading Mihomo's internal goroutine cleanup code, we cannot determine the severity.

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **Conditionally** — depends on Mihomo's internal goroutine cleanup guarantees |
| Restart safe? | **Yes** — if Mihomo guarantees goroutines drain before Shutdown returns |
| Process restart required? | **Required** if Mihomo does not guarantee full drain |
| CAS safely releasable? | **Yes** — happens normally |
| Split-brain risk? | **Medium** — data races possible if leaked goroutines touch global state post-restart |

---

## Scenario 4: JNI thread permanently blocked

### Description

In the current Kotlin architecture, `Veercore.start()` is called on a `Dispatchers.IO` thread.
This is a direct JNI call that blocks the calling OS thread for the duration of `Veercore.start`'s
execution. `withTimeoutOrNull` cannot interrupt it (V2 in `native_runtime_contract.md`).

In the cooperative lifecycle proposal, `Runtime.Start()` is non-blocking — it launches
`initGoroutine` and returns immediately. `WaitReady(timeoutMs)` blocks (via a `select` on
`r.ready` and `time.After`) for a bounded duration. The blocking call in `WaitReady` is a
pure Go channel select, not a JNI call, so `withTimeoutOrNull` cannot interrupt it either,
but `time.After` in Go provides the bound independently of the Kotlin timeout mechanism.

### Current architecture (VeerVpnService)

`Veercore.start()` may hang indefinitely. The `Dispatchers.IO` thread is permanently consumed.
Android has a bounded pool of IO threads; exhausting them stalls all coroutines waiting for IO
dispatchers. After the start timeout fires (`withTimeoutOrNull` returns null), the coroutine
continues but the IO thread remains blocked until the JNI call returns or the process dies.

**Recoverability (current):** Process restart required if the thread is never released.
Kotlin-side engineMutex ensures no second `Veercore.start()` call is issued, which prevents
a second thread from being consumed, but the first remains blocked indefinitely.

### Proposed architecture (Runtime.Start + WaitReady)

`Runtime.Start()` returns immediately. `WaitReady(timeoutMs)` is bounded by a `time.After`
in Go. When `WaitReady` returns false (timeout), Kotlin calls `Cancel()` → `Stop(timeoutMs)`.
This eliminates the JNI-thread-blocking scenario for the startup path.

`Runtime.Stop(timeoutMs)` calls `executor.Shutdown()` inside `shutdownGoroutine` and blocks
for `timeoutMs` via `time.After`. This is again a pure Go select, not a blocking JNI call.
`Cleanup()` waits for `shutdownGoroutine` to complete via a done channel, with its own timeout.

**Recoverability (proposed):** Scenario 4 is resolved by the proposal's non-blocking `Start()`.
All bounded waits are implemented with Go `time.After`, guaranteeing they fire regardless of
JNI cancellation semantics.

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **Current: No.** Proposed: Yes (WaitReady is bounded) |
| Restart safe? | **Current: No.** Proposed: Conditional (see Scenarios 1–2) |
| Process restart required? | **Current: Yes**, if thread block is permanent |
| CAS safely releasable? | **Current: Yes** (CAS not used). Proposed: Force-release path needed |
| Split-brain risk? | **Current: Low** (mutex prevents second start). Proposed: Low |

---

## Scenario 5: Lost runtime ownership CAS

### Description

`globalActive.CompareAndSwap(r, nil)` is called from `unregisterGlobal()`, which is in
`shutdownGoroutine`'s defer chain. If `shutdownGoroutine` never completes (Scenarios 1, 2,
or 8), `unregisterGlobal()` never runs. The CAS permanently holds a non-nil pointer.

Secondary case: a bug causes `unregisterGlobal()` to be called with the wrong pointer
(e.g., a Runtime that was already replaced). The CAS check `CompareAndSwap(r, nil)` fails
silently. The CAS continues to hold the old pointer.

### State

`globalActive` holds a pointer to a dead or dying Runtime. Every call to
`globalActive.CompareAndSwap(nil, r)` in `NewRuntime()` → `Start()` returns false.
No new Runtime can be created. VPN cannot be restarted without process death.

### Recovery analysis

**In-process fix:** A force-release path in `Cleanup()`'s timeout handler must call
`globalActive.CompareAndSwap(r, nil)` (or `globalActive.Store(nil)` as a last resort, at
the cost of not being atomic with respect to a theoretical concurrent `Start()` call). The
`Store(nil)` path must be guarded by a separate `cleanupOnce sync.Once` to prevent double
execution.

**Secondary case (wrong pointer):** The `CompareAndSwap(r, nil)` in `unregisterGlobal()` will
fail if `r` is not the current value. This can only happen if `unregisterGlobal()` is called
on a Runtime that was never registered, which the proposed design prevents (registration
happens in `Start()` via the same CAS, so any `Runtime.r` that made it past `Start()` is the
registered pointer). The risk is low in the proposed design but must be verified in the
implementation.

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **Yes** — force-release path in Cleanup() timeout handler |
| Restart safe after force-release? | **Conditional** — only if underlying goroutines are not in split-brain |
| Process restart required? | **No** — if force-release path is implemented correctly |
| CAS safely releasable? | **Yes** — force-release path |
| Split-brain risk? | **Low from CAS itself** — the CAS is a singleton gate, not Mihomo state |

---

## Scenario 6: Partial fd ownership leak

### Description

The `initGoroutine` calls `syscall.Dup(int(tunFd))` and stores `r.fdDup` immediately. The
original `tunFd` is a Java `int` referring to the Android `ParcelFileDescriptor`'s underlying
fd. The Go-side dup is the only resource that `shutdownGoroutine` must close.

If `shutdownGoroutine` never completes (Scenarios 1, 2), `closeFdDup()` never runs. The
kernel fd refcount for the dup remains non-zero. The Android `ParcelFileDescriptor.close()`
decrements the refcount for the original fd but does not affect the dup. The tun interface
remains open at the kernel level (from the Go dup's perspective) even after `VeerVpnService`
has destroyed its end of the fd.

Practical consequence: the Linux VPN subsystem may keep the tun device open, preventing
Android from creating a new tun interface for the next VPN session, or causing the next
`VpnService.Builder.establish()` call to fail or return a stale device.

### Recovery analysis

**Force-release path in `Cleanup()`:**
```go
r.closeFdDupOnce.Do(func() {
    if r.fdDup > 0 {
        syscall.Close(r.fdDup)
        r.fdDup = -1
    }
})
```
This must execute regardless of whether `shutdownGoroutine` has completed. The `sync.Once`
ensures it runs exactly once even if both `shutdownGoroutine`'s defer and `Cleanup()`'s
timeout handler race to close it.

**After fd dup is closed:** The kernel tun device refcount reaches zero (assuming no other
references). Android can then establish a new tun interface. However, if `initGoroutine`
or `shutdownGoroutine` continues running and later calls any Go function that reads from the
tun fd, it will get `EBADF`. The `defer recover()` in each goroutine catches the resulting
panic (if the fd read is wrapped in Go code that panics) or produces an error return.

**`sync.Once` is mandatory** for `closeFdDup`. The `shutdownGoroutine`'s defers run after
`executor.Shutdown()` returns, which may be after `Cleanup()`'s timeout handler has already
closed the fd. Without `Once`, double-close produces `EBADF` on a potentially recycled fd
number — a security-relevant bug (the recycled fd could belong to a different file).

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **Yes** — force-release path with `sync.Once` |
| Restart safe after cleanup? | **Yes** — kernel tun device is released |
| Process restart required? | **No** — if force-release path is implemented |
| CAS safely releasable? | **Yes** |
| Split-brain risk? | **Low** — fd ownership is independent of Mihomo global executor state |

---

## Scenario 7: Panic during shutdown

### Description

`executor.Shutdown()` panics (e.g., nil pointer dereference inside Mihomo's teardown code).
In the cooperative lifecycle proposal, `shutdownGoroutine` wraps `executor.Shutdown()` in a
`defer func() { if r := recover(); r != nil { ... } }()`. The recover catches the panic,
records it in `r.lastErr`, transitions Phase to `Failed`, and returns.

Three sub-scenarios:

**7a. Panic is caught by the defer in `shutdownGoroutine`:**
- `executor.Shutdown()` completed partially (panic happened mid-teardown).
- Some Mihomo subsystems may not be shut down.
- Leaked goroutines (Scenario 3) are likely.
- `shutdownGoroutine` exits normally after the recover. Defers for `closeFdDup()` and
  `unregisterGlobal()` run.
- Phase reaches `Failed` (5). CAS is released. fd dup is closed.
- A new Runtime can be created, but Scenario 3 applies.

**7b. Panic occurs in a goroutine spawned by `executor.Shutdown()` (not the calling goroutine):**
- `defer recover()` in `shutdownGoroutine` does NOT catch panics in other goroutines.
- The spawned goroutine's panic propagates up to the Go runtime's unhandled panic handler.
- **This terminates the entire Android process immediately.** The JVM is not involved.
- Android OS restarts the app (if the service is `START_STICKY`). This is a hard process restart.

**7c. Panic occurs in an already-running Mihomo background goroutine (not in Shutdown itself):**
- Same as 7b — the Go runtime terminates the process.
- `VeerVpnService.onDestroy()` is not called before process termination.
- `runBlocking { tearDownCore() }` never executes.
- Android restarts the process; `VeerVpnService` may be recreated if `START_STICKY`.

### Critical distinction

`defer recover()` only catches panics on the same goroutine's stack. Panics in goroutines
spawned by `executor.ApplyConfig` or `executor.Shutdown` cannot be caught from `initGoroutine`
or `shutdownGoroutine`. Any unhandled panic in a Mihomo background goroutine terminates the
process — this is not a VeerVpnService design failure but a fundamental Go runtime invariant.

### Recoverability

| Scenario | Process restart required? | CAS releasable? | Split-brain risk? |
|---|---|---|---|
| 7a — caught panic | No | Yes (via defer) | Medium (Scenario 3) |
| 7b — goroutine panic | **Yes — process terminated** | N/A | N/A |
| 7c — background goroutine panic | **Yes — process terminated** | N/A | N/A |

---

## Scenario 8: Goroutine leaks after timeout paths

### Description

This is the most operationally dangerous scenario because it arises from the normal timeout
handling path — the path that is supposed to provide bounded behavior.

**Timeline:**
1. `WaitReady(timeoutMs)` returns false — `initGoroutine` did not signal `r.ready` in time.
2. Kotlin calls `Cancel()` → `Stop(timeoutMs)`.
3. `shutdownGoroutine` starts and calls `executor.Shutdown()`.
4. `Stop(timeoutMs)` times out — `executor.Shutdown()` is still running.
5. Kotlin calls `Cleanup()`.
6. `Cleanup()` times out — `shutdownGoroutine` is still running.
7. Force-release path runs: `closeFdDup()`, `CAS.CompareAndSwap(r, nil)`.
8. Kotlin calls `Start()` on a new Runtime.
9. New Runtime calls `executor.ApplyConfig()`.

**At step 9:** `shutdownGoroutine` (from step 3) is still blocked in `executor.Shutdown()`.
`executor.ApplyConfig()` is simultaneously running from the new Runtime.
This is a split-brain condition at the Mihomo global executor level.

**Additionally:** `initGoroutine` (from step 1) is still blocked in `executor.ApplyConfig()`.
Now there are three concurrent calls into Mihomo global state:
- Old `initGoroutine`: old `ApplyConfig` (blocked)
- Old `shutdownGoroutine`: `Shutdown` (blocked)
- New `initGoroutine`: new `ApplyConfig` (starting)

### `close(r.ready)` double-close risk

`r.ready` is closed when `initGoroutine` signals readiness (success path) OR when
`shutdownGoroutine` force-closes it to unblock any `WaitReady` calls (shutdown path).
If both paths execute concurrently, `close(r.ready)` is called twice. In Go, closing an
already-closed channel panics unconditionally.

**Required protection:**
```go
var readyOnce sync.Once
// In initGoroutine success path:
readyOnce.Do(func() { close(r.ready) })
// In shutdownGoroutine, to unblock WaitReady:
readyOnce.Do(func() { close(r.ready) })
```
Without `readyOnce`, the panic from double-close terminates the process (Scenario 7b).
This is a design-level flaw in the lifecycle proposal that must be corrected before implementation.

### Recoverability

| Question | Answer |
|---|---|
| In-process cleanup possible? | **CAS and fd: Yes** (force-release). Goroutines: No |
| Restart (new Runtime) safe? | **No** — concurrent old goroutines in Mihomo global executor |
| Process restart required? | **Yes** — the only way to terminate zombie goroutines |
| CAS safely releasable? | **Yes** — force-release path |
| Split-brain risk? | **Critical** — up to three concurrent goroutines in executor |

---

## Design Flaws Identified in Lifecycle Proposal

The following implementation-blocking flaws were identified through this analysis.
They must be corrected before any implementation of `runtime_lifecycle_proposal.md`.

### Flaw F1: `closeFdDup` and `unregisterGlobal` exclusively in `shutdownGoroutine` defers

**Impact:** If `shutdownGoroutine` never exits (Scenarios 2, 4, 8), these resources are
never released. The process cannot create a new Runtime (CAS held). The kernel tun device
remains open (fd dup held).

**Required fix:** `Cleanup()`'s timeout handler must include a force-release path:
```go
// After Stop() returns ErrStopTimeout AND Cleanup() times out waiting for shutdownGoroutine:
r.closeFdDupOnce.Do(func() { syscall.Close(r.fdDup) })
globalActive.CompareAndSwap(r, nil)
```

### Flaw F2: `close(r.ready)` called from multiple goroutines without `sync.Once`

**Impact:** Double-close panics the process (Scenario 8, Go runtime invariant). This is a
correctness defect, not a theoretical concern — the timeout path deliberately triggers both
the init goroutine's success path and the shutdown goroutine's drain path.

**Required fix:**
```go
type Runtime struct {
    // ...
    ready     chan struct{}
    readyOnce sync.Once
}

func (r *Runtime) signalReady() {
    r.readyOnce.Do(func() { close(r.ready) })
}
```
All `close(r.ready)` call sites replaced with `r.signalReady()`.

### Flaw F3: Double `executor.Shutdown()` in `applyWithContextCheck` + `shutdownGoroutine`

**Impact:** The proposal's `applyWithContextCheck` function calls `executor.Shutdown()` when
its context is cancelled, and `shutdownGoroutine` also calls `executor.Shutdown()`. Two
concurrent `Shutdown()` calls are undefined behavior at the Mihomo level (Scenario 2 risk).

**Required fix:** `executor.Shutdown()` must be wrapped in a `sync.Once`:
```go
var shutdownOnce sync.Once

func (r *Runtime) shutdownMihomo() {
    shutdownOnce.Do(func() { executor.Shutdown() })
}
```
`applyWithContextCheck` must NOT call `executor.Shutdown()` directly. It must only signal
the cancel context and allow `shutdownGoroutine` to call `shutdownMihomo()` via `Once`.

### Flaw F4: No guaranteed force-release path for the CAS on all exit paths

**Impact:** If `Cleanup()` is never called (caller bug), the CAS is held forever. This is
an API contract issue.

**Required fix:** Document explicitly that `Cleanup()` must always be called, and add a
`runtime.SetFinalizer(r, (*Runtime).finalize)` that performs emergency force-release if
`Cleanup()` was never called. This cannot guarantee safety (GC finalizers have no ordering
guarantees) but provides a last-resort defense against the CAS being permanently held.

---

## Recovery Classification Table

| Scenario | Description | In-Process Cleanup | Restart Safe? | Process Restart |
|---|---|---|---|---|
| 1 | Hung ApplyConfig | **Conditional** | No (zombie) | Required if goroutine persists |
| 2 | Deadlocked Shutdown | No | No (split-brain) | **Always required** |
| 3 | Leaked Mihomo goroutines | **Conditional** | If Mihomo drains correctly | Required if Mihomo races |
| 4 (current arch) | JNI thread blocked | No | No | **Required** |
| 4 (proposed arch) | WaitReady timeout | Yes (bounded by Go time.After) | Conditional | Not required if force-release implemented |
| 5 | Lost CAS | **Yes** (force-release) | Conditional | Not required |
| 6 | fd dup leak | **Yes** (sync.Once + force-release) | Yes | Not required |
| 7a | Caught panic in Shutdown | **Yes** (via defer) | Conditional (Scenario 3) | Not required |
| 7b/7c | Uncaught goroutine panic | No (process terminated) | N/A | **Required** (automatic) |
| 8 | Goroutine leaks post-timeout | CAS+fd: Yes. Goroutines: No | No (split-brain) | **Required** |

---

## Fundamental Hard Limit

**Mihomo's `executor` package uses global process state. The process is the unit of isolation.**

`executor.ApplyConfig` and `executor.Shutdown` are not instance methods — they operate on a
global proxy table, global rule engine, global DNS cache, and global connection pools. There
is no Mihomo-level mechanism to run two independent Mihomo configurations in the same process,
and no Mihomo-level mechanism to terminate a goroutine that is executing inside `executor`.

This imposes an inescapable architectural constraint:

1. **A zombie `initGoroutine` blocked in `ApplyConfig` cannot be reclaimed.** Starting a new
   Runtime after force-releasing the CAS creates a split-brain condition. The new
   `ApplyConfig` and the zombie `ApplyConfig` are racing on global Mihomo state.

2. **A deadlocked `shutdownGoroutine` in `Shutdown` cannot be reclaimed.** Starting a new
   Runtime after force-releasing the CAS creates a split-brain condition. The new `ApplyConfig`
   and the blocked `Shutdown` are racing on global Mihomo state.

3. **Go goroutines cannot be killed.** There is no `pthread_cancel` equivalent. A goroutine
   blocked in a kernel syscall (socket read, file write) or in JNI will remain until the
   syscall completes or the process dies.

4. **`withTimeoutOrNull` cannot interrupt blocking JNI or kernel syscalls.** Kotlin's coroutine
   cancellation only fires at suspension points. A blocking JNI call has no suspension point.
   (V2 in `native_runtime_contract.md`. Resolved only for startup by the proposed
   non-blocking `Start()` + Go-side `WaitReady`.)

### What in-process recovery actually provides

The force-release path (CAS + fd dup) is necessary and worth implementing. It ensures that:
- The Android VPN subsystem does not hold an open tun device indefinitely.
- The Runtime singleton gate is cleared, so the user can attempt to reconnect.
- Subsequent `WaitReady` callers are not permanently blocked.

But CAS release with persistent zombie goroutines in Mihomo global state is not "recovery" —
it is "clearing the gate while the building is on fire." The fire (split-brain) persists until
process death.

### Operational recommendation

**Recovery decision matrix:**

| Condition | Action |
|---|---|
| `Stop()` returns success AND `shutdownGoroutine` exits cleanly | Safe to restart in-process |
| `Stop()` returns `ErrStopTimeout` | Force-release, then **require process restart** before new VPN session |
| `Cleanup()` times out | Force-release, then **require process restart** before new VPN session |
| Uncaught goroutine panic (7b/7c) | Process terminates; Android restarts via `START_STICKY` |
| `WaitReady()` returns false, `Stop()` succeeds | Safe to restart in-process |
| `WaitReady()` returns false, `Stop()` fails | **Require process restart** |

**Android-side enforcement:** When `Stop()` or `Cleanup()` times out, `VeerVpnService` must
set `EngineState.Error` and NOT re-launch the VPN within the same service instance. The user
must manually reconnect, which will trigger a new `startForegroundService()` call, OS process
restart, and a clean slate for all Go goroutines.

This is the only architecturally honest recovery strategy given Go's goroutine model and
Mihomo's global executor state.
