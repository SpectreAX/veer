# Veer Runtime Validation Harness

**Goal:** Every lifecycle invariant in `runtime_invariants.md` becomes empirically testable.
Every non-recoverable failure class in `runtime_nonrecoverable_states.md` has a reproducible
injection path. Every JNI call has a measurable duration. Every goroutine leak is detectable.

**Status:** Design specification — not yet implemented.

**Companion documents:**
- `runtime_invariants.md` — invariants under test (referenced as §N.N)
- `native_runtime_contract.md` — JNI contract (V1, V2, UB1, etc.)
- `runtime_nonrecoverable_states.md` — failure scenarios (S1–S8, F1–F4)
- `runtime_lifecycle_proposal.md` — future Go-side API (Runtime struct)
- `process_isolation_architecture.md` — A2 isolation target for Phase 2

---

## 1. Production Safety Boundaries

All fault injection and observability infrastructure is gated by two independent mechanisms
that must BOTH be active for any test-only code path to execute. Neither gate is sufficient
alone.

**Gate G1 — Go build tag `veer_fault_inject`:**
Fault injection code lives exclusively in files with `//go:build veer_fault_inject` as their
first non-blank, non-comment line. The production `.aar` is built without this tag. Tag
presence in the production binary is an inadvertent defect, not a documented risk.

**Gate G2 — Kotlin debug source set + `BuildConfig.FAULT_INJECT`:**
All Kotlin test infrastructure lives in `app/src/debug/java/` (the Android debug source set).
This directory is excluded from release APK compilation entirely. Additionally,
`BuildConfig.FAULT_INJECT = true` is a `buildConfigField` set only in the `debug` build
variant. Every debug-only call site in shared source is wrapped with:
```kotlin
if (BuildConfig.DEBUG && BuildConfig.FAULT_INJECT) { ... }
```

**What must never appear in a production build:**
- Goroutine stack dumps (may contain proxy hostnames, API keys from config)
- Open fd listings (leaks internal file descriptor state)
- Hang gates (can cause ANR if accidentally triggered)
- Any function that accepts a string argument interpreted as a fault specifier
- The `MihomoRepository.setForTest()` override path
- Any AIDL endpoint not declared in the main manifest

**Verification:** The release CI job must include a `grep` step that asserts neither
`"veer_fault_inject"` nor `"FaultInjector"` appears in the compiled release APK's DEX or
native `.so` binaries. The `gomobile bind` invocation for release must never include
`-tags=veer_fault_inject`.

---

## 2. Build Configuration

### 2.1 Go build variants

```makefile
# go_core/Makefile (or build script)

# Production .aar — no fault injection symbols
.PHONY: aar-release
aar-release:
	gomobile bind \
	  -target=android \
	  -androidapi 29 \
	  -o ../app/libs/libveer_core.aar \
	  .

# Debug .aar — fault injection + metrics compiled in
.PHONY: aar-debug
aar-debug:
	gomobile bind \
	  -target=android \
	  -androidapi 29 \
	  -tags=veer_fault_inject \
	  -o ../app/libs/libveer_core_debug.aar \
	  .
```

### 2.2 Gradle variant selection

```kotlin
// app/build.gradle.kts
android {
    buildTypes {
        debug {
            buildConfigField("boolean", "FAULT_INJECT", "true")
        }
        release {
            buildConfigField("boolean", "FAULT_INJECT", "false")
        }
    }
}

dependencies {
    debugImplementation(files("libs/libveer_core_debug.aar"))
    releaseImplementation(files("libs/libveer_core.aar"))
}
```

### 2.3 Go file layout

```
go_core/
  veer_core.go             ← production code, no build tag
  veer_fault_inject.go     ← //go:build veer_fault_inject
  veer_metrics.go          ← //go:build veer_fault_inject
  veer_goroutine_snap.go   ← //go:build veer_fault_inject
  veer_phase_trace.go      ← //go:build veer_fault_inject
  veer_noop_stubs.go       ← //go:build !veer_fault_inject  (empty stubs for production)
```

The `veer_noop_stubs.go` file exports all fault injection function names as no-ops so that
`veer_core.go` can call them unconditionally without conditional compilation at each call site:

```go
// veer_noop_stubs.go
//go:build !veer_fault_inject

package veercore

// All functions are no-ops; eliminated by the compiler.
func triggerHook(name string) error { return nil }
func recordCallStart(name string) func(err *error) { return func(*error) {} }
```

---

## 3. Fault Injection Architecture — Go Side

### 3.1 FaultSpec and the hook registry

```go
// veer_fault_inject.go
//go:build veer_fault_inject

package veercore

import (
    "errors"
    "runtime"
    "sync"
    "sync/atomic"
    "time"
)

// FaultSpec describes a single fault at a named hook point.
// Fields are applied in order: delay → hang → panic/error.
type FaultSpec struct {
    // DelayMs: sleep this many milliseconds before the hook fires.
    // Does not block the calling goroutine's select — uses time.Sleep.
    DelayMs int64

    // HangDurationMs: block this many milliseconds. -1 = block until
    // ReleaseHang(hookName) is called. 0 = no hang.
    HangDurationMs int64

    // PanicOnCallingGoroutine: panic on the goroutine that triggered the hook.
    // The enclosing defer recover() will catch this (maps to a Java exception).
    // Use this to test the start-error cleanup path.
    PanicOnCallingGoroutine string // non-empty = panic with this message

    // PanicOnNewGoroutine: spawn a new goroutine that panics after DelayMs.
    // This goroutine has NO recover() — it will terminate the process.
    // Use this to test Scenario 7b (process death recovery).
    // ONLY set this in tests that are designed to measure post-restart state.
    PanicOnNewGoroutine string // non-empty = panic in background goroutine

    // ReturnError: return this string as an error from the hook point.
    // Applies when the hook is at an error-returning call site.
    ReturnError string
}

var (
    hooksMu   sync.RWMutex
    hookSpecs = map[string]*FaultSpec{}
    hangGates = map[string]chan struct{}{} // closed by ReleaseHang
)

// SetFaultHook installs a fault at the named hook point, replacing any prior
// spec. Pass nil to clear the hook.
func SetFaultHook(hookName string, spec *FaultSpec) {
    hooksMu.Lock()
    defer hooksMu.Unlock()
    if spec == nil {
        delete(hookSpecs, hookName)
        delete(hangGates, hookName)
        return
    }
    hookSpecs[hookName] = spec
    if spec.HangDurationMs == -1 {
        hangGates[hookName] = make(chan struct{})
    }
}

// ReleaseHang unblocks any goroutine currently suspended at hookName with
// HangDurationMs == -1. Safe to call before or after the hang goroutine arrives.
func ReleaseHang(hookName string) {
    hooksMu.Lock()
    ch := hangGates[hookName]
    delete(hangGates, hookName)
    delete(hookSpecs, hookName)
    hooksMu.Unlock()
    if ch != nil {
        close(ch)
    }
}

// ClearAllFaults removes all installed faults and releases all hang gates.
// Call from test teardown to ensure a clean state for the next test.
func ClearAllFaults() {
    hooksMu.Lock()
    defer hooksMu.Unlock()
    for _, ch := range hangGates {
        select {
        case <-ch:
        default:
            close(ch)
        }
    }
    hookSpecs = map[string]*FaultSpec{}
    hangGates = map[string]chan struct{}{}
}

// triggerHook executes the fault spec registered at hookName, if any.
// Returns a non-nil error if the spec has ReturnError set.
// This function is inlined into the production no-op stub.
func triggerHook(hookName string) error {
    hooksMu.RLock()
    spec := hookSpecs[hookName]
    ch := hangGates[hookName]
    hooksMu.RUnlock()

    if spec == nil {
        return nil
    }

    if spec.DelayMs > 0 {
        time.Sleep(time.Duration(spec.DelayMs) * time.Millisecond)
    }

    if spec.HangDurationMs == -1 && ch != nil {
        <-ch // blocks until ReleaseHang closes the channel
    } else if spec.HangDurationMs > 0 {
        time.Sleep(time.Duration(spec.HangDurationMs) * time.Millisecond)
    }

    if spec.PanicOnCallingGoroutine != "" {
        panic(spec.PanicOnCallingGoroutine)
    }

    if spec.PanicOnNewGoroutine != "" {
        msg := spec.PanicOnNewGoroutine
        go func() {
            // No recover() — this goroutine's panic terminates the process.
            // Callers must set this only in process-death recovery tests.
            time.Sleep(time.Duration(spec.DelayMs) * time.Millisecond)
            panic(msg)
        }()
    }

    if spec.ReturnError != "" {
        return errors.New(spec.ReturnError)
    }
    return nil
}
```

### 3.2 Named hook points

```go
// Hook point constants — all call sites use these names.
const (
    // Fires immediately before executor.ApplyConfig in Start().
    // HangDurationMs here simulates a hung ApplyConfig (Scenario 1).
    // ReturnError here simulates a config-apply failure.
    HookBeforeApplyConfig = "before_apply_config"

    // Fires from inside a goroutine spawned by the hook, after ApplyConfig
    // has been called. PanicOnNewGoroutine here simulates Scenario 7b.
    HookDuringApplyConfig = "during_apply_config"

    // Fires immediately before executor.Shutdown() in Stop().
    // HangDurationMs here simulates a hung Shutdown (Scenario 2).
    HookBeforeShutdown = "before_shutdown"

    // Fires immediately after executor.Shutdown() returns.
    // ReturnError here simulates a Shutdown failure return.
    HookAfterShutdown = "after_shutdown"

    // Fires before syscall.Dup in Start(). ReturnError simulates Dup failure.
    HookBeforeFdDup = "before_fd_dup"

    // Fires in the forwardLogs goroutine on each iteration.
    // HangDurationMs here simulates a slow log consumer.
    HookLogForwarder = "log_forwarder"

    // Fires inside every SocketProtector.Protect() call.
    // ReturnError makes Protect return false.
    HookProtector = "protector"
)
```

### 3.3 Hook instrumentation in `veer_core.go`

The production `veer_core.go` is instrumented minimally. Each call site for the noop stubs is
a single line; the compiler eliminates them in production builds.

```go
// In Start():
func Start(homeDir string, configName string, tunFd int32) (err error) {
    defer func() {
        if r := recover(); r != nil {
            err = fmt.Errorf("mihomo start panic: %v", r)
        }
    }()

    // ... parse + configure cfg ...

    if hookErr := triggerHook(HookBeforeApplyConfig); hookErr != nil {
        return fmt.Errorf("fault-injected before ApplyConfig: %w", hookErr)
    }

    executor.ApplyConfig(cfg, true)
    _ = triggerHook(HookDuringApplyConfig) // used only for PanicOnNewGoroutine

    log.Infoln("mihomo started; home=%s tunFd=%d", homeDir, tunFd)
    return nil
}

// In Stop():
func Stop() (err error) {
    defer func() {
        if r := recover(); r != nil {
            err = fmt.Errorf("mihomo stop panic: %v", r)
        }
    }()
    if hookErr := triggerHook(HookBeforeShutdown); hookErr != nil {
        return fmt.Errorf("fault-injected before Shutdown: %w", hookErr)
    }
    executor.Shutdown()
    _ = triggerHook(HookAfterShutdown)
    log.Infoln("mihomo stopped")
    return nil
}
```

---

## 4. Fault Injection Architecture — Kotlin Side

### 4.1 `FaultInjector` debug-only object

Location: `app/src/debug/java/com/yamax/veer/testing/FaultInjector.kt`

```kotlin
// Debug source set only — not compiled in release.
package com.yamax.veer.testing

import veercore.Veercore

/**
 * Thin Kotlin wrapper over the Go fault injection API.
 * Every method is a no-op if the Go .aar was not built with veer_fault_inject.
 * Check BuildConfig.FAULT_INJECT before calling.
 */
object FaultInjector {

    // ---- Go-side hook control ----

    fun setApplyConfigHang(durationMs: Long = -1L) {
        Veercore.setFaultHook("before_apply_config", durationMs, "", "")
    }

    fun setShutdownHang(durationMs: Long = -1L) {
        Veercore.setFaultHook("before_shutdown", durationMs, "", "")
    }

    fun setApplyConfigError(message: String) {
        Veercore.setFaultHook("before_apply_config", 0L, "", message)
    }

    fun setBackgroundGoroutinePanic(message: String, delayMs: Long = 100L) {
        // PanicOnNewGoroutine — process will terminate. Only for death-recovery tests.
        Veercore.setFaultHookPanic("during_apply_config", delayMs, message)
    }

    fun releaseHang(hookName: String) {
        Veercore.releaseHang(hookName)
    }

    fun clearAll() {
        Veercore.clearAllFaults()
    }

    // ---- Kotlin-side lifecycle overrides ----

    /**
     * Installs a mock MihomoRepository that returns null for version() probes.
     * This triggers the watchdog detection path without modifying Mihomo.
     * The mock is cleared automatically on the next MihomoRepository.get() call
     * after clearAll() is called, or explicitly via [clearAll].
     */
    fun injectWatchdogFailure() {
        MihomoRepositoryOverride.install(NullVersionRepository())
    }

    fun clearRepositoryOverride() {
        MihomoRepositoryOverride.clear()
    }
}
```

### 4.2 Testable `MihomoRepository` override

The production singleton path in `MihomoRepository.get()` must support injection
without modifying production code. Add a debug-only override layer:

```kotlin
// app/src/debug/java/com/yamax/veer/testing/MihomoRepositoryOverride.kt
package com.yamax.veer.testing

import com.yamax.veer.core_mihomo.MihomoRepository

internal object MihomoRepositoryOverride {
    @Volatile private var override: MihomoRepository? = null

    fun install(repo: MihomoRepository) { override = repo }
    fun clear() { override = null }
    fun get(): MihomoRepository? = override
}
```

```kotlin
// Modification to MihomoRepository.get() — production file, debug guard:
fun get(): MihomoRepository {
    if (BuildConfig.DEBUG && BuildConfig.FAULT_INJECT) {
        MihomoRepositoryOverride.get()?.let { return it }
    }
    return INSTANCE ?: synchronized(this) {
        INSTANCE ?: MihomoRepository().also { INSTANCE = it }
    }
}
```

### 4.3 `NullVersionRepository` (watchdog trigger)

```kotlin
// app/src/debug/java/com/yamax/veer/testing/NullVersionRepository.kt
package com.yamax.veer.testing

import com.yamax.veer.core_mihomo.MihomoRepository

/** Returns null for every version() call; always-failing for all other calls. */
internal class NullVersionRepository : MihomoRepository() {
    override suspend fun version(): String? = null
}
```

### 4.4 Watchdog time acceleration

The watchdog uses constants `WATCHDOG_INITIAL_DELAY_MS = 15_000L` and
`WATCHDOG_INTERVAL_MS = 30_000L` defined in `VeerVpnService.Companion`. These values make
real-time watchdog tests take >45 seconds each.

Add a debug-only override path. In `VeerVpnService`:

```kotlin
private val watchdogInitialDelayMs: Long
    get() = if (BuildConfig.FAULT_INJECT)
        FaultTimings.watchdogInitialDelayMs
    else
        WATCHDOG_INITIAL_DELAY_MS

private val watchdogIntervalMs: Long
    get() = if (BuildConfig.FAULT_INJECT)
        FaultTimings.watchdogIntervalMs
    else
        WATCHDOG_INTERVAL_MS
```

```kotlin
// app/src/debug/java/com/yamax/veer/testing/FaultTimings.kt
object FaultTimings {
    @Volatile var watchdogInitialDelayMs: Long = 1_000L  // 1 s for tests
    @Volatile var watchdogIntervalMs: Long    = 2_000L  // 2 s for tests
    @Volatile var stopTimeoutMs: Long         = 6_000L  // unchanged default

    fun reset() {
        watchdogInitialDelayMs = 1_000L
        watchdogIntervalMs = 2_000L
        stopTimeoutMs = 6_000L
    }
}
```

---

## 5. Observability Infrastructure

### 5.1 Goroutine inventory snapshots

**Go-side API** (`veer_goroutine_snap.go`, `//go:build veer_fault_inject`):

```go
package veercore

import (
    "runtime"
    "sync"
    "time"
)

// GoroutineSnapshot is a point-in-time capture of the Go goroutine population.
type GoroutineSnapshot struct {
    Count     int    // runtime.NumGoroutine() at snapshot time
    Timestamp int64  // Unix milliseconds
    Stacks    string // full runtime.Stack output; empty if includeStacks=false
}

var (
    snapMu    sync.Mutex
    snapshots []*GoroutineSnapshot
)

// TakeGoroutineSnapshot captures current goroutine count.
// Set includeStacks=true only in debugging contexts — the output can be
// several hundred kilobytes for a busy runtime.
func TakeGoroutineSnapshot(includeStacks bool) *GoroutineSnapshot {
    count := runtime.NumGoroutine()
    snap := &GoroutineSnapshot{
        Count:     count,
        Timestamp: time.Now().UnixMilli(),
    }
    if includeStacks {
        buf := make([]byte, 128*1024)
        n := runtime.Stack(buf, true)
        snap.Stacks = string(buf[:n])
    }
    snapMu.Lock()
    snapshots = append(snapshots, snap)
    snapMu.Unlock()
    return snap
}

// GoroutineDelta returns after.Count - before.Count.
// A positive value means goroutines were created; negative means they exited.
// After a clean stop+cleanup cycle this should be ≤ 0.
func GoroutineDelta(before, after *GoroutineSnapshot) int {
    return after.Count - before.Count
}

// GetStoredSnapshots returns all snapshots taken since the last ClearSnapshots call.
func GetStoredSnapshots() []*GoroutineSnapshot {
    snapMu.Lock()
    defer snapMu.Unlock()
    cp := make([]*GoroutineSnapshot, len(snapshots))
    copy(cp, snapshots)
    return cp
}

func ClearSnapshots() {
    snapMu.Lock()
    snapshots = snapshots[:0]
    snapMu.Unlock()
}
```

**Kotlin-side wrapper** (debug source set):

```kotlin
object GoroutineInventory {
    data class Snapshot(val count: Int, val timestampMs: Long, val stacks: String)

    fun take(includeStacks: Boolean = false): Snapshot {
        val raw = Veercore.takeGoroutineSnapshot(includeStacks)
        return Snapshot(raw.count, raw.timestamp, raw.stacks ?: "")
    }

    fun delta(before: Snapshot, after: Snapshot): Int = after.count - before.count

    /**
     * Blocks until [predicate] is true or [timeoutMs] elapses.
     * Use for: "wait until goroutine count returns to baseline".
     * Polls every [intervalMs] milliseconds.
     */
    suspend fun awaitCondition(
        timeoutMs: Long,
        intervalMs: Long = 200L,
        predicate: (Snapshot) -> Boolean,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate(take())) return true
            kotlinx.coroutines.delay(intervalMs)
        }
        return false
    }
}
```

**Usage in tests:**
```kotlin
val baseline = GoroutineInventory.take()
// ... start + stop cycle ...
// Allow up to 1s for forwardLogs goroutine to drain.
val stable = GoroutineInventory.awaitCondition(timeoutMs = 1_000) { snap ->
    GoroutineInventory.delta(baseline, snap) <= 1
}
assertThat(stable).isTrue()
```

---

### 5.2 Tun fd snapshot

On Android, `/proc/self/fd/` lists all open file descriptors as symlinks. The symlink target
names identify the resource type (e.g., `anon_inode:[N]`, `/dev/tun`, `socket:[N]`).

```kotlin
// app/src/debug/java/com/yamax/veer/testing/FdSnapshot.kt
object FdSnapshot {

    data class Entry(val fd: Int, val target: String)
    data class Diff(val opened: List<Entry>, val closed: List<Entry>)

    /**
     * Returns all open fds for [pid] (default: current process).
     * Returns empty map if /proc/pid/fd is not accessible (release builds, SELinux).
     */
    fun snapshot(pid: Int = android.os.Process.myPid()): Map<Int, Entry> {
        val dir = java.io.File("/proc/$pid/fd")
        return dir.listFiles()
            ?.mapNotNull { link ->
                val fdNum = link.name.toIntOrNull() ?: return@mapNotNull null
                val target = runCatching { link.canonicalPath }.getOrDefault("?")
                fdNum to Entry(fdNum, target)
            }
            ?.toMap()
            ?: emptyMap()
    }

    fun diff(before: Map<Int, Entry>, after: Map<Int, Entry>): Diff {
        val opened = (after.keys - before.keys).map { after[it]!! }
        val closed = (before.keys - after.keys).map { before[it]!! }
        return Diff(opened, closed)
    }

    /** Returns true if no tun-related fd appears in [after] that was not in [before]. */
    fun noTunLeak(before: Map<Int, Entry>, after: Map<Int, Entry>): Boolean {
        val diff = diff(before, after)
        return diff.opened.none { it.target.contains("tun", ignoreCase = true) }
    }

    /**
     * Total fd count delta. Should be ≤ 0 (or ≤ small positive for system fd churn)
     * after a complete start + stop cycle.
     */
    fun countDelta(before: Map<Int, Entry>, after: Map<Int, Entry>): Int =
        after.size - before.size
}
```

**Important limitation:** On Android API ≥ 29, reading `/proc/other-pid/fd/` for a process
with a different UID requires `PTRACE_ATTACH` capability. Reading `/proc/self/fd/` (same
process) is always permitted. For A2 architecture tests (where the tun fd dup lives in the
`:veercore` process), the fd snapshot must be taken from within the `:veercore` process
via a dedicated AIDL call or Go-exported function.

---

### 5.3 Phase transition trace

Captures every `EngineState` transition with timestamp and calling context. Zero overhead in
production (trace ring buffer not allocated).

```kotlin
// app/src/debug/java/com/yamax/veer/testing/PhaseTrace.kt
object PhaseTrace {

    data class Event(
        val state: String,           // EngineState class name
        val timestampMs: Long,
        val threadName: String,
        val callerStackLine: String, // first non-PhaseTrace frame
    )

    private val events = ArrayDeque<Event>(64)
    private val lock = java.util.concurrent.locks.ReentrantLock()

    fun record(state: EngineState) {
        if (!BuildConfig.FAULT_INJECT) return
        val ts = System.currentTimeMillis()
        val thread = Thread.currentThread().name
        val caller = Thread.currentThread().stackTrace
            .firstOrNull { it.className != PhaseTrace::class.java.name &&
                           !it.className.contains("MihomoEngine") }
            ?.let { "${it.className.substringAfterLast('.')}:${it.lineNumber}" }
            ?: "unknown"
        lock.withLock {
            if (events.size >= 64) events.removeFirst()
            events.addLast(Event(state::class.simpleName ?: state.toString(), ts, thread, caller))
        }
    }

    fun drain(): List<Event> = lock.withLock { events.toList().also { events.clear() } }
    fun peek(): List<Event> = lock.withLock { events.toList() }
    fun clear() = lock.withLock { events.clear() }

    /**
     * Asserts that the phase sequence [expected] appears as a contiguous
     * subsequence of the recorded events (not necessarily the full trace).
     */
    fun assertSequenceContains(vararg expected: String) {
        val names = peek().map { it.state }
        val idx = Collections.indexOfSubList(names, expected.toList())
        check(idx >= 0) {
            "Expected phase sequence $expected not found in $names"
        }
    }
}
```

**Hook into `MihomoEngine.setState`** (production file, debug guard):

```kotlin
internal fun setState(next: EngineState) {
    if (BuildConfig.DEBUG && BuildConfig.FAULT_INJECT) {
        PhaseTrace.record(next)
    }
    _state.value = next
}
```

---

### 5.4 JNI call duration metrics

**Go-side** (`veer_metrics.go`, `//go:build veer_fault_inject`):

```go
package veercore

import (
    "encoding/json"
    "sync"
    "time"
)

type CallMetric struct {
    Name      string `json:"name"`
    StartedAt int64  `json:"started_at_us"` // Unix microseconds
    DurationUs int64 `json:"duration_us"`
    Succeeded bool   `json:"succeeded"`
    Error     string `json:"error,omitempty"`
}

var (
    metricsMu sync.Mutex
    callLog   []*CallMetric
)

// recordCallStart returns a deferred finish function. Usage:
//   func Start(...) (err error) {
//       finish := recordCallStart("Start")
//       defer finish(&err)
//       ...
//   }
func recordCallStart(name string) func(err *error) {
    m := &CallMetric{Name: name, StartedAt: time.Now().UnixMicro()}
    return func(err *error) {
        m.DurationUs = time.Now().UnixMicro() - m.StartedAt
        m.Succeeded = err == nil || *err == nil
        if err != nil && *err != nil {
            m.Error = (*err).Error()
        }
        metricsMu.Lock()
        if len(callLog) >= 256 {
            callLog = callLog[1:] // sliding window
        }
        callLog = append(callLog, m)
        metricsMu.Unlock()
    }
}

// GetCallMetricsJSON returns all recorded metrics as a JSON array string.
// Callable from Kotlin via JNI.
func GetCallMetricsJSON() string {
    metricsMu.Lock()
    defer metricsMu.Unlock()
    b, _ := json.Marshal(callLog)
    return string(b)
}

func ClearCallMetrics() {
    metricsMu.Lock()
    callLog = callLog[:0]
    metricsMu.Unlock()
}
```

**Instrumentation in `veer_core.go`:**

```go
func Start(homeDir string, configName string, tunFd int32) (err error) {
    finish := recordCallStart("Start")
    defer finish(&err)
    defer func() {
        if r := recover(); r != nil {
            err = fmt.Errorf("mihomo start panic: %v", r)
        }
    }()
    // ... rest of implementation ...
}

func Stop() (err error) {
    finish := recordCallStart("Stop")
    defer finish(&err)
    defer func() {
        if r := recover(); r != nil {
            err = fmt.Errorf("mihomo stop panic: %v", r)
        }
    }()
    // ... rest of implementation ...
}
```

**Kotlin wrapper** (debug source set):

```kotlin
object JniCallMetrics {
    data class Metric(
        val name: String,
        val startedAtUs: Long,
        val durationUs: Long,
        val succeeded: Boolean,
        val error: String?,
    )

    fun collect(): List<Metric> {
        val json = Veercore.getCallMetricsJSON() ?: return emptyList()
        return kotlinx.serialization.json.Json.decodeFromString(json)
    }

    fun clear() = Veercore.clearCallMetrics()

    /** Assert the last call to [name] completed within [limitMs] ms. */
    fun assertCallWithin(name: String, limitMs: Long) {
        val m = collect().lastOrNull { it.name == name }
            ?: error("No recorded call named $name")
        val actualMs = m.durationUs / 1_000
        check(actualMs <= limitMs) {
            "$name took ${actualMs}ms, exceeded limit of ${limitMs}ms"
        }
    }
}
```

---

### 5.5 Required observability points summary

| Point | Mechanism | Layer | Production overhead |
|---|---|---|---|
| `EngineState` transitions | `PhaseTrace.record()` in `setState()` | Kotlin | Zero (guarded by `BuildConfig.FAULT_INJECT`) |
| Go goroutine count | `runtime.NumGoroutine()` | Go | Zero (called only by test) |
| Go goroutine stacks | `runtime.Stack(buf, true)` | Go | Zero (called only by test) |
| Open fd count | `/proc/self/fd/` listing | Kotlin | Zero (called only by test) |
| JNI call duration | `recordCallStart` defer wrapper | Go | Zero (no-op stub in production) |
| Fault hook firing | `triggerHook()` inlined calls | Go | Zero (no-op stub eliminates code) |
| Hook gate blocking | channel receive in `triggerHook` | Go | Zero (gate map is empty) |
| Watchdog timing | `FaultTimings.*` fields | Kotlin | Zero (compile-time constant path) |

---

## 6. Test Case Catalog

Each test is identified by **T-ID**, mapped to the invariant(s) it validates, and classified
by execution mode.

### Classification key

| Mode | Execution | Infrastructure |
|---|---|---|
| **AUTO** | `./gradlew connectedDebugAndroidTest` | Instrumented on device/emulator |
| **SEMI** | Instrumented + explicit external release step | Hang gate or timing dependency |
| **MANUAL** | `adb shell` script or physical observation | Process death; cannot survive in test runner |

---

### T-01 — Normal lifecycle, clean start and stop

**Validates:** §1.1, §1.2, §3.2 (full state sequence), §2.1, §2.2

**Precondition:** VPN permission granted. No faults installed.

**Procedure:**
1. Record goroutine baseline: `baseline = GoroutineInventory.take()`
2. Record fd baseline: `fdBefore = FdSnapshot.snapshot()`
3. `PhaseTrace.clear()`
4. Start VPN via `VeerVpnService.startIntent(ctx)`.
5. Await `EngineState.Running` with 10s timeout.
6. Stop VPN via `VeerVpnService.stopIntent(ctx)`.
7. Await `EngineState.Stopped` with 10s timeout.
8. Wait 500ms for goroutine drain.
9. Record post-stop: `after = GoroutineInventory.take()`, `fdAfter = FdSnapshot.snapshot()`

**Assertions:**
```kotlin
PhaseTrace.assertSequenceContains("Starting", "Running", "Stopping", "Stopped")
assertThat(GoroutineInventory.delta(baseline, after)).isAtMost(1)
assertThat(FdSnapshot.countDelta(fdBefore, fdAfter)).isAtMost(0)
assertThat(FdSnapshot.noTunLeak(fdBefore, fdAfter)).isTrue()
```

**Mode:** AUTO

---

### T-02 — `VpnService.establish()` returns null

**Validates:** §2.1 (tun establish failure), §6.1 (all failures produce observable state)

**Precondition:** Mock VPN builder to return null. This requires
`VeerVpnService` to accept a builder factory for testing. In the current architecture,
this is done by disabling VPN permission before the test (`adb shell pm revoke`) so
`establish()` returns null.

**Procedure:**
1. Revoke VPN permission: `adb shell pm revoke com.yamax.veer android.permission.VPN` — or
   deny the VPN consent dialog if it appears.
2. Start VPN.
3. Await `EngineState.Error` with 5s timeout.

**Assertions:**
```kotlin
assertThat(engine.state.value).isInstanceOf(EngineState.Error::class.java)
PhaseTrace.assertSequenceContains("Starting", "Error")
// Veercore.start was never called: startAttempted should not have been set.
// Verify: no Veercore stop metric recorded (no start was attempted).
assertThat(JniCallMetrics.collect().none { it.name == "Stop" }).isTrue()
```

**Mode:** MANUAL (permission manipulation requires device interaction)

---

### T-03 — Config parse failure (`base.yaml` corrupted)

**Validates:** §7.4 (corrupt ai_override.yaml), §6.1 (error state), §1.1 (start not called after
config failure)

**Procedure:**
1. Write invalid YAML to `filesDir/mihomo/base.yaml` (or `ai_override.yaml`).
2. Start VPN.
3. Await `EngineState.Error` with 5s timeout.

**Assertions:**
```kotlin
PhaseTrace.assertSequenceContains("Starting", "Error")
// Start was not reached: no JNI "Start" call recorded.
assertThat(JniCallMetrics.collect().none { it.name == "Start" }).isTrue()
assertThat(engine.state.value).isInstanceOf(EngineState.Error::class.java)
```

**Note:** After this test, restore `base.yaml` from assets via `ConfigManager.prepare()`.

**Mode:** AUTO

---

### T-04 — `Veercore.start()` returns error (injected)

**Validates:** V1 from `native_runtime_contract.md` (`startAttempted` flag), §6.1, §3.2

**Precondition:** `veer_fault_inject` .aar installed.

**Procedure:**
1. `FaultInjector.setApplyConfigError("injected-start-failure")`
2. Record goroutine baseline.
3. Start VPN.
4. Await `EngineState.Error` then `EngineState.Stopped`.
5. Verify stop was called (cleanup path executed).

**Assertions:**
```kotlin
PhaseTrace.assertSequenceContains("Starting", "Error", "Stopping", "Stopped")
// Veercore.stop() was called despite start failing (V1 fix):
val stopCall = JniCallMetrics.collect().lastOrNull { it.name == "Stop" }
assertThat(stopCall).isNotNull()
// Goroutines returned to baseline:
val after = GoroutineInventory.take()
assertThat(GoroutineInventory.delta(baseline, after)).isAtMost(1)
```

**Mode:** AUTO (requires debug .aar)

---

### T-05 — `Veercore.start()` hangs past `STOP_TIMEOUT_MS` (Scenario 1)

**Validates:** §4.4 (JNI not cancellable), §2.4 (forced close), STOP_TIMEOUT_MS enforcement

**Precondition:** `veer_fault_inject` .aar installed.

**Procedure:**
1. `FaultInjector.setApplyConfigHang(-1L)` — infinite hang.
2. Record fd baseline.
3. Start VPN.
4. Await `EngineState.Starting` (confirms `bootCore` is in-progress).
5. Wait `STOP_TIMEOUT_MS + 2000ms = 8000ms`.
6. The service's `onDestroy` should have been triggered by some mechanism —
   in this test, simulate it by sending `ACTION_STOP` at step 4+100ms.
7. Verify: `EngineState` transitions to `Stopped` after timeout.
8. `FaultInjector.releaseHang("before_apply_config")` — unblock the goroutine (cleanup).

**Assertions:**
```kotlin
PhaseTrace.assertSequenceContains("Starting", "Stopping", "Stopped")
val fdAfter = FdSnapshot.snapshot()
assertThat(FdSnapshot.noTunLeak(fdBefore, fdAfter)).isTrue()
// The JNI Start call duration should be ≥ 6000ms (timeout fired before it returned):
val startCall = JniCallMetrics.collect().lastOrNull { it.name == "Start" }
// Note: this assertion may fail if the JNI thread is still blocked — Start has not yet
// returned. This is the V2 limitation: record the observation, not a hard assertion.
```

**Important observation:** After this test, the JNI IO thread remains blocked indefinitely
until `releaseHang` is called. This is the V2 behaviour (documented as unfixable in the
current architecture). Release the hang before the next test or the IO thread pool degrades.

**Mode:** SEMI (hang release is a manual external step)

---

### T-06 — `Veercore.stop()` / `executor.Shutdown()` hangs → `EngineState.Error` (§3.2 `Stopping → Error`)

**Validates:** `STOP_JNI_TIMEOUT_MS` (Layer 2 CountDownLatch) fires before `Veercore.stop()` returns;
service transitions to `EngineState.Error` (NOT `Stopped`) per `runtime_invariants.md §3.2 / §3.5`;
daemon thread orphaned, split-brain risk surfaced to user.

**Precondition:** `veer_fault_inject` .aar with `HookBeforeShutdown` compiled in (SI-08 in
`runtime_stability_plan.md §6`). Test skips automatically when the hook is absent.

**Procedure:**
1. Start VPN normally. Await `Running`.
2. `FaultInjector.hangBeforeShutdown(-1L)` — infinite hang inside `executor.Shutdown()`.
3. `PhaseTrace.clear()`.
4. Stop VPN via `ACTION_STOP`.
5. Await `EngineState.Error` with `STOP_JNI_TIMEOUT_MS + 3000ms = 8000ms` timeout.

**Assertions:**
```kotlin
// Layer 2 latch (STOP_JNI_TIMEOUT_MS = 5000ms) must have fired:
// terminal state is Error, NOT Stopped.
assertTrue(
    "Expected Stopping → Error when JNI stop times out (§3.2)",
    PhaseTrace.containsSequence("Stopping", "Error"),
)
assertFalse(
    "Stopping → Stopped must NOT occur here — that would be a §3.2 violation",
    PhaseTrace.containsSequence("Stopping", "Stopped"),
)
val errorState = MihomoEngine.state.value as? EngineState.Error
assertNotNull("EngineState must be Error after JNI timeout", errorState)
assertTrue(
    "Error message must indicate timeout and need to restart",
    errorState!!.message.contains("timed out", ignoreCase = true) ||
        errorState.message.contains("restart", ignoreCase = true),
)
// Tun fd must be closed despite orphaned Shutdown goroutine:
assertThat(FdSnapshot.noTunLeak(fdBefore, fdAfter)).isTrue()
// Timing: Error must be reached within STOP_JNI_TIMEOUT_MS + 1500ms of Stopping:
val errorEvent   = PhaseTrace.peek().firstOrNull { it.stateName == "Error" }
val stoppingEvent = PhaseTrace.peek().firstOrNull { it.stateName == "Stopping" }
assertThat(errorEvent!!.timestampMs - stoppingEvent!!.timestampMs)
    .isAtMost(STOP_JNI_TIMEOUT_MS + 1500)
```

**After-test:** `FaultInjector.releaseShutdownHang()` to unblock the orphaned daemon thread
(also called automatically by `FaultInjector.clearAll()` in `@After`).

**Relationship to T-05 (Layer 1 timeout):** T-05 tests Layer 1 (`STOP_TIMEOUT_MS`, coroutine
mutex-wait timeout) → terminal state `Stopped`. T-06 tests Layer 2 (`STOP_JNI_TIMEOUT_MS`,
CountDownLatch JNI timeout) → terminal state `Error`. These are distinct paths and must
not be conflated.

**Mode:** SEMI (hang release is an external step; can be made AUTO by using
`hangBeforeShutdown(durationMs = STOP_JNI_TIMEOUT_MS + 2000)` finite hang)

---

### T-07 — Background goroutine panic terminates process (Scenario 7b)

**Validates:** Go runtime behaviour on unhandled goroutine panic, `START_STICKY` recovery,
post-restart VPN re-establishment

**Precondition:** `veer_fault_inject` .aar installed. External observation infrastructure
(logcat capture, device state logging) prepared.

**Procedure:**
1. Start VPN. Await `Running`.
2. `FaultInjector.setBackgroundGoroutinePanic("test-panic", delayMs = 500L)`.
3. Wait 1000ms.
4. **The process terminates.** The test runner (if in-process) also terminates.

**Post-death verification (external):**
- `adb logcat -d | grep "FATAL EXCEPTION"` — verifies panic message appears.
- `adb shell dumpsys activity services com.yamax.veer` — verifies VeerVpnService
  is listed (Android restarted it via `START_STICKY`).
- `adb shell cat /proc/$(pidof com.yamax.veer)/status` — verifies new process running.

**Mode:** MANUAL — cannot be automated in-process for A1 architecture.
In A2 architecture, this becomes AUTO: kill the `:veercore` process; the test process
survives and observes `DeathRecipient.binderDied()` firing, then restart.

---

### T-08 — Rapid connect/disconnect races on `engineMutex` (§1.4)

**Validates:** `engineMutex` serialization prevents double-start and double-stop

**Procedure:**
1. Start VPN via `startIntent`.
2. Immediately (within 50ms) send `stopIntent`.
3. Verify: single `bootCore` proceeds to completion (or single error path).
4. Repeat 10 times with random 0–100ms gap.

**Assertions:**
```kotlin
// No double-start: "bootCore ignored — already running" log may appear,
// but exactly 0 or 1 Running states are reached per cycle.
val runningCount = PhaseTrace.drain().count { it.state == "Running" }
assertThat(runningCount).isAtMost(1)
// Veercore.start called at most once:
assertThat(JniCallMetrics.collect().count { it.name == "Start" }).isAtMost(1)
// Veercore.stop called at most once:
assertThat(JniCallMetrics.collect().count { it.name == "Stop" }).isAtMost(1)
```

**Mode:** AUTO

---

### T-09 — Double `ACTION_START` — idempotency guard (§1.3)

**Validates:** `coreRunning` check in `bootCore`, §1.3 at-most-one-runtime invariant

**Procedure:**
1. Start VPN. Await `Running`.
2. Send `ACTION_START` again.
3. Wait 500ms.

**Assertions:**
```kotlin
// Only one Running state ever entered:
assertThat(PhaseTrace.peek().count { it.state == "Running" }).isEqualTo(1)
// Second start logged as ignored:
val logs = MihomoEngine.logs.replayCache
assertThat(logs.any { "bootCore ignored" in it }).isTrue()
// JNI Start called exactly once:
assertThat(JniCallMetrics.collect().count { it.name == "Start" }).isEqualTo(1)
```

**Mode:** AUTO

---

### T-10 — `onRevoke()` routes through single shutdown path (§1.2)

**Validates:** `onRevoke()` → `stopSelf()` → `onDestroy()` → `tearDownCore()` — not a
direct `Veercore.stop()` call

**Procedure:**
1. Start VPN. Await `Running`.
2. Record `JniCallMetrics.clear()`.
3. Call `service.onRevoke()` directly via instrumentation (or disconnect via Settings).
4. Await `EngineState.Stopped`.

**Assertions:**
```kotlin
PhaseTrace.assertSequenceContains("Stopping", "Stopped")
// Exactly one Stop JNI call — not two (which would indicate dual-path teardown):
assertThat(JniCallMetrics.collect().count { it.name == "Stop" }).isEqualTo(1)
```

**Mode:** AUTO (via `InstrumentationRegistry.getInstrumentation()` to access service)

---

### T-11 — Watchdog detects API unreachable (§5.1, §5.2)

**Validates:** Watchdog fires on null version(), sets Error, calls stopSelf — does NOT
call Veercore.stop() directly (§5.1 critical invariant)

**Procedure:**
1. Set `FaultTimings.watchdogInitialDelayMs = 1000`, `FaultTimings.watchdogIntervalMs = 2000`.
2. Start VPN. Await `Running`.
3. `FaultInjector.injectWatchdogFailure()` — installs null-returning repository.
4. Wait `watchdogInitialDelayMs + watchdogIntervalMs + connectTimeout + 2000ms = 10000ms`.
5. Await `EngineState.Error`.
6. Await `EngineState.Stopped`.

**Assertions:**
```kotlin
PhaseTrace.assertSequenceContains("Running", "Error", "Stopping", "Stopped")
// Stop JNI call happened via tearDownCore, not directly from watchdog:
// (confirm by checking that Stop appears only after Stopping state):
val stoppingTs = PhaseTrace.peek().first { it.state == "Stopping" }.timestampMs
val stopMetric = JniCallMetrics.collect().last { it.name == "Stop" }
assertThat(stopMetric.startedAt / 1000).isAtLeast(stoppingTs)
```

**Mode:** AUTO (with `FaultTimings` acceleration)

---

### T-12 — Goroutine count stability over N restart cycles (no leak)

**Validates:** No goroutine leak accumulates across repeated start/stop cycles (S3, S8
partial mitigation verification)

**Procedure:**
1. `baseline = GoroutineInventory.take()`
2. Repeat N = 10 times:
   a. Start VPN. Await `Running`.
   b. Stop VPN. Await `Stopped`.
   c. Wait 500ms.
3. `after = GoroutineInventory.take()`

**Assertions:**
```kotlin
val delta = GoroutineInventory.delta(baseline, after)
// Allow ≤ 2 goroutines net increase across 10 cycles (system goroutines may fluctuate).
// Any delta > 4 indicates a goroutine leak.
assertThat(delta).isAtMost(4)
```

**Failure interpretation:** If delta > 4 after N cycles, take a stack snapshot:
```kotlin
val stacks = GoroutineInventory.take(includeStacks = true)
Log.d("VeerTest", stacks.stacks) // inspect for veercore frames
```

**Mode:** AUTO (slow; ~N × 5s per cycle = ~50s total)

---

### T-13 — fd count stability (no leak across start/stop)

**Validates:** §2.2 Go-side dup closed, §2.3 teardownTun called

**Procedure:**
1. `fdBefore = FdSnapshot.snapshot()`
2. Start VPN. Await `Running`.
3. Stop VPN. Await `Stopped`. Wait 300ms.
4. `fdAfter = FdSnapshot.snapshot()`

**Assertions:**
```kotlin
val diff = FdSnapshot.diff(fdBefore, fdAfter)
// Net fd increase should be 0 (same as before start).
// Allow +2 for system-level fd churn (e.g., Logcat sockets).
assertThat(FdSnapshot.countDelta(fdBefore, fdAfter)).isAtMost(2)
// Specifically, no tun-related fd should remain open:
assertThat(FdSnapshot.noTunLeak(fdBefore, fdAfter)).isTrue()
// Log all opened fds for debugging if the assertion fails:
diff.opened.forEach { Log.d("VeerTest", "fd ${it.fd} → ${it.target}") }
```

**Mode:** AUTO

---

### T-14 — Logger detachment ordering (§2.2 teardown order)

**Validates:** `Veercore.setLogger(null)` is called AFTER `Veercore.stop()` and BEFORE
`tearDownTun()`. No log delivery after detachment.

**Procedure:**
1. Install a log counter: wrap `VeerLogger` to count deliveries with timestamps.
2. Start VPN. Await `Running`.
3. Stop VPN. Await `Stopped`.
4. Record: `lastLogDeliveryMs` (last timestamp a log was received in VeerLogger).
5. Record: `setLoggerNullMs` (timestamp of `Veercore.setLogger(null)` call — add trace point).
6. Record: `tearDownTunMs` (timestamp of `tearDownTun()` call — add trace point).

**Assertions:**
```kotlin
// All deliveries happened before setLogger(null):
assertThat(lastLogDeliveryMs).isAtMost(setLoggerNullMs + 50) // 50ms grace
// setLogger(null) happened before tearDownTun:
assertThat(setLoggerNullMs).isLessThan(tearDownTunMs)
// No NullPointerException in log delivery during teardown:
assertThat(logDeliveryExceptions).isEmpty()
```

**Mode:** AUTO (requires minor instrumentation additions to `tearDownCore`)

---

### T-15 — Forbidden state transition: no direct `setState` from outside module

**Validates:** §3.3 (forbidden transitions), `internal` visibility of `setState`

**Procedure:** Compile-time assertion — attempt to call `MihomoEngine.setState(...)` from
`MainActivity` or any test class outside the `core_mihomo` package.

**Expected result:** Kotlin compiler error: `Cannot access 'setState': it is internal in
'com.yamax.veer.core_mihomo'`.

**Mode:** AUTO (compile-time — add a negative compilation test to the CI script):
```bash
# In CI: verify the production source does not contain any setState call
# from outside core_mihomo. This is a static analysis check, not a runtime test.
grep -rn "MihomoEngine.setState" app/src/main/java/ \
  | grep -v "core_mihomo/" \
  | (read line && echo "VIOLATION: $line" && exit 1 || exit 0)
```

---

### T-16 — JNI call duration baseline (warm start)

**Validates:** JNI calls complete within acceptable bounds. Establishes a regression baseline.

**Procedure:**
1. Start device. Wait 30s (filesystem warmed by ambient reads).
2. Start VPN once (cold start, discarded — warms the cache).
3. Stop VPN. Wait 2s.
4. `JniCallMetrics.clear()`
5. Start VPN. Await `Running`.
6. Stop VPN. Await `Stopped`.
7. Collect metrics.

**Assertions:**
```kotlin
JniCallMetrics.assertCallWithin("Start", limitMs = 5_000)
JniCallMetrics.assertCallWithin("Stop", limitMs = 3_000)
```

**Note:** These limits are intentionally generous. Tighten them per-device after establishing
empirical baselines. Add to CI with device-specific thresholds if test matrix is available.

**Mode:** AUTO

---

### T-17 — `START_STICKY` null intent re-establishment (§7.4)

**Validates:** Null intent in `onStartCommand` falls through to `bootCore()`, VPN
re-establishes after process death

**Procedure:**
1. Start VPN. Await `Running`.
2. Force process death: `adb shell am force-stop com.yamax.veer`.
3. Wait 3s for Android `START_STICKY` restart.
4. Check: VPN active via `adb shell dumpsys connectivity | grep VPN`.

**Assertions (external):**
- `dumpsys connectivity | grep "VPN active"` confirms tunnel is up.
- `logcat | grep "mihomo core started"` confirms new start sequence.

**Mode:** MANUAL (process death terminates test runner)

---

### T-18 — Concurrent `bootCore` + `tearDownCore` under `engineMutex` (stress)

**Validates:** §1.4 mutex serialization prevents concurrent JNI calls, split-brain

**Procedure:**
1. Launch 4 concurrent coroutines, each randomly alternating between `startIntent` and
   `stopIntent` 20 times with 0–200ms random delays.
2. Run for 30s total.

**Assertions:**
```kotlin
// No concurrent Veercore.start calls (would be undefined behavior):
val startCalls = JniCallMetrics.collect().filter { it.name == "Start" }
// Verify no two Start calls overlap:
startCalls.sortedBy { it.startedAt }.zipWithNext { a, b ->
    val aEnd = a.startedAt + a.durationUs
    assertThat(b.startedAt).isAtLeast(aEnd) // b starts after a ends
}
// Same for Stop:
val stopCalls = JniCallMetrics.collect().filter { it.name == "Stop" }
stopCalls.sortedBy { it.startedAt }.zipWithNext { a, b ->
    assertThat(b.startedAt).isAtLeast(a.startedAt + a.durationUs)
}
// No process crash detected (no unexpected restarts):
assertThat(processRestartCount).isEqualTo(0)
```

**Mode:** AUTO (requires JNI metrics; 30s duration)

---

### T-19 — Forced process death recovery (A2 architecture target)

**Validates:** For A2: `:veercore` process death → `DeathRecipient.binderDied()` fires →
main process restarts `:veercore` → VPN re-establishes. For A1: process restart and VPN
re-establishment via `START_STICKY`.

**A1 procedure:**
1. VPN running.
2. `adb shell kill -9 $(pidof com.yamax.veer)`.
3. External: wait 3s, check VPN active.

**A2 procedure (future):**
1. Bind to `:veercore` service. Register `DeathRecipient`.
2. Get `:veercore` PID via AIDL `getPid()` call.
3. `adb shell kill -9 <veerocorePid>` (or `Process.killProcess(pid)` from test).
4. **Test survives** (main process unaffected).
5. Await `DeathRecipient.binderDied()` within 2s.
6. Await `EngineState.Running` (after restart) within 5s.

**Mode:** MANUAL for A1; AUTO for A2.

---

## 7. Automated vs Manual Validation Paths

### Automated suite (CI-runnable)

```
T-03  Config parse failure
T-04  Injected start error (startAttempted flag)
T-08  Rapid connect/disconnect stress
T-09  Double ACTION_START idempotency
T-10  onRevoke routing
T-11  Watchdog null-version detection (accelerated timing)
T-12  Goroutine count stability (N=10 cycles)
T-13  fd count stability
T-14  Logger detachment ordering
T-15  Forbidden setState (static analysis)
T-16  JNI call duration baseline
T-18  Concurrent engineMutex stress
```

Prerequisite: physical device or emulator with VPN permission pre-granted.
Run: `./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yamax.veer.testing.LifecycleInvariantSuite`

### Semi-automated (hang tests, require external gate release)

```
T-05  ApplyConfig hang + timeout (hang must be released post-assertion)
T-06  Shutdown hang + force-close (hang must be released post-assertion)
```

These can be made fully automated by using `HangDurationMs = STOP_TIMEOUT_MS + 2000`
(finite hang, not infinite gate) at the cost of the test taking 8+ seconds each.

### Manual (process death scenarios)

```
T-02  VPN permission revocation
T-07  Background goroutine panic (process terminates)
T-17  START_STICKY null intent
T-19  Forced process death recovery (A1)
```

For T-07 and T-17, provide a shell script:
```bash
#!/bin/bash
# test_process_death.sh
PKG="com.yamax.veer"
adb logcat -c
adb shell am start -n $PKG/.MainActivity
sleep 3
# VPN should be running; trigger death
adb shell am force-stop $PKG
sleep 5
# Check restart
adb shell dumpsys activity services $PKG | grep VeerVpnService
adb logcat -d | grep "mihomo core started" | tail -3
```

---

## 8. Invariant-to-Test Coverage Map

| Invariant | Test(s) |
|---|---|
| §1.1 Sole caller of Veercore.start | T-04, T-08, T-09, T-18 |
| §1.2 Sole caller of Veercore.stop | T-10, T-11, T-14 |
| §1.3 At most one live Go runtime | T-09, T-18 |
| §1.4 Start and stop serialized by engineMutex | T-08, T-18 |
| §2.1 tun fd ownership | T-01, T-13 |
| §2.2 fd handoff to Go, teardown order | T-13, T-14 |
| §2.3 teardown guarantee | T-06, T-13 |
| §2.4 Forced close on timeout | T-05, T-06 |
| §2.5 No fd reuse after teardown begins | T-08 (no second tun while stopping) |
| §3.2 Legal state transitions | T-01, T-04, T-11 |
| §3.3 Forbidden transitions | T-15 |
| §3.4 Error semantics | T-04, T-11 |
| §3.5 Stopping semantics | T-06 |
| §4.2 SupervisorJob | T-08 (one child failure does not kill scope) |
| §4.3 Dispatchers.IO deadlock avoidance | T-05, T-06 (timeout must not deadlock) |
| §4.4 JNI non-cancellability (V2) | T-05 (observation, not assertion) |
| §5.1 Watchdog observation only | T-11 (Stop JNI after Stopping state) |
| §5.2 Watchdog check mechanism | T-11 |
| §5.3 Initial delay | T-11 (accelerated) |
| §6.1 All failures produce observable state | T-02, T-03, T-04, T-11 |
| §6.2 No silent coroutine death | T-08, T-18 (CoroutineExceptionHandler) |
| §7.4 START_STICKY null intent | T-17 |
| native_runtime_contract V1 | T-04 (startAttempted ensures cleanup) |
| native_runtime_contract V2 | T-05 (observation) |
| S1 Hung ApplyConfig | T-05 |
| S2 Hung Shutdown | T-06 |
| S7b Goroutine panic | T-07 |
| F2 close(r.ready) double-close | Not yet testable (cooperative lifecycle not implemented) |

---

## 9. CI Pipeline Integration

### 9.1 Job structure

```yaml
# .github/workflows/validate.yml (sketch)
jobs:
  build-debug-aar:
    runs-on: ubuntu-latest
    steps:
      - name: Build fault-inject AAR
        run: cd go_core && make aar-debug

  static-checks:
    steps:
      - name: No setState outside core_mihomo
        run: |
          grep -rn "MihomoEngine.setState" app/src/main/java/ \
            | grep -v "core_mihomo/" && exit 1 || true
      - name: No fault_inject in release AAR
        run: |
          strings app/libs/libveer_core.aar | grep -q "veer_fault_inject" && exit 1 || true

  instrumented-tests:
    needs: [build-debug-aar]
    runs-on: [self-hosted, android-device]
    steps:
      - name: Grant VPN permission
        run: adb shell pm grant com.yamax.veer android.permission.VPN || true
      - name: Run lifecycle invariant suite
        run: ./gradlew :app:connectedDebugAndroidTest
          -Pandroid.testInstrumentationRunnerArguments.class=
          com.yamax.veer.testing.LifecycleInvariantSuite
          --info
      - name: Upload goroutine + fd reports
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: goroutine-stacks
          path: build/outputs/androidTest-results/
```

### 9.2 Pre-consent emulator snapshot

VPN permission requires user consent dialogs that cannot be automated on standard emulators
without a Device Policy Controller. Maintain a pre-consented emulator snapshot:

```bash
# One-time setup:
emulator -avd Pixel_9_API_35 -no-snapshot-load &
adb wait-for-device
# Navigate manually: Settings → VPN → Veer → Allow
adb emu avd snapshot save veer-vpn-consented
# Future CI:
emulator -avd Pixel_9_API_35 -snapshot veer-vpn-consented &
```

### 9.3 Goroutine leak regression gate

```kotlin
// LifecycleInvariantSuite.kt
@Test fun goroutineLeakRegressionGate() {
    // Run 5 cycles; fail CI if delta > threshold.
    val baseline = GoroutineInventory.take()
    repeat(5) {
        startAndAwaitRunning()
        stopAndAwaitStopped()
        delay(500)
    }
    val delta = GoroutineInventory.delta(baseline, GoroutineInventory.take())
    if (delta > 4) {
        val stacks = GoroutineInventory.take(includeStacks = true)
        fail("Goroutine leak: delta=$delta after 5 cycles\n${stacks.stacks}")
    }
}
```

---

## 10. A2 Process Isolation Test Extensions (Future)

When `VeerVpnService` moves to the `:veercore` process (Phase 2, Architecture A2), the
following test extensions become available:

### 10.1 Binder death simulation (T-07 automated)

```kotlin
// In A2 test:
val deathLatch = CountDownLatch(1)
veerCoreService.asBinder().linkToDeath({ deathLatch.countDown() }, 0)

// Inject goroutine panic via AIDL (replaces FaultInjector which is in-process):
veerCoreService.setFaultHook("during_apply_config", panicMessage = "test")

// The :veercore process terminates. Main process survives.
assertThat(deathLatch.await(3, TimeUnit.SECONDS)).isTrue()
// Verify state transition in main process:
PhaseTrace.assertSequenceContains("Error")
```

### 10.2 `:veercore` fd verification

```kotlin
// From main process, read fd state of :veercore process:
val veerocorePid = veerCoreService.getPid()
val fdsBefore = FdSnapshot.snapshot(veerocorePid)
// ... stop :veercore ...
// After process death, /proc/<old-pid>/fd no longer exists — which IS the
// verification: all fds in that namespace are reclaimed by kernel on process exit.
assertThat(File("/proc/$veerocorePid/fd").exists()).isFalse()
```

### 10.3 Cross-process JNI metric collection

In A2, `JniCallMetrics` live in the `:veercore` process. Expose them via AIDL:

```aidl
// IVeerCoreService.aidl
String getCallMetricsJson();
void clearCallMetrics();
```

Main process calls `veerCoreService.getCallMetricsJson()`, deserializes, and runs the same
assertions as the A1 instrumented tests. The test API surface is identical; only the
transport changes from in-process JNI to Binder.
