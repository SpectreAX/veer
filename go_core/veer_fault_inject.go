//go:build veer_fault_inject

package veercore

import (
	"errors"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// Internal hook registry
// ---------------------------------------------------------------------------

var (
	hooksMu   sync.RWMutex
	hangGates = map[string]chan struct{}{} // closed by release call
	hangDurs  = map[string]time.Duration{} // finite hang durations
	errorMsgs = map[string]string{}
	panicMsgs = map[string]string{}

	bgPanicMu  sync.Mutex
	bgPanicStr string // empty = no active background panic

	startCount int32 // atomic; incremented at entry of Start()
	stopCount  int32 // atomic; incremented at entry of Stop()
)

// triggerHook fires the fault installed at hookName, if any.
// Returns non-nil error only when ReturnError is set.
// Called unconditionally from veer_core.go; the production build uses a
// zero-cost no-op stub from veer_noop_stubs.go.
func triggerHook(hookName string) error {
	hooksMu.RLock()
	gate, hasGate := hangGates[hookName]
	dur, hasDur := hangDurs[hookName]
	errMsg := errorMsgs[hookName]
	panicMsg := panicMsgs[hookName]
	hooksMu.RUnlock()

	if hasGate {
		<-gate // blocks until ReleaseHang* closes the channel
	} else if hasDur {
		time.Sleep(dur)
	}

	if panicMsg != "" {
		panic(panicMsg)
	}
	if errMsg != "" {
		return errors.New(errMsg)
	}
	return nil
}

func incrStartCount() { atomic.AddInt32(&startCount, 1) }
func incrStopCount()  { atomic.AddInt32(&stopCount, 1) }

// ---------------------------------------------------------------------------
// Exported API — callable from Kotlin via gomobile JNI
// ---------------------------------------------------------------------------

// SetFaultHangBeforeApplyConfig installs a hang at the ApplyConfig hook point
// inside Start(). durationMs < 0 blocks until ReleaseHangBeforeApplyConfig;
// durationMs > 0 sleeps for that many milliseconds; durationMs == 0 clears.
func SetFaultHangBeforeApplyConfig(durationMs int64) {
	hooksMu.Lock()
	defer hooksMu.Unlock()
	delete(hangGates, "before_apply_config")
	delete(hangDurs, "before_apply_config")
	if durationMs < 0 {
		hangGates["before_apply_config"] = make(chan struct{})
	} else if durationMs > 0 {
		hangDurs["before_apply_config"] = time.Duration(durationMs) * time.Millisecond
	}
}

// ReleaseHangBeforeApplyConfig unblocks any goroutine waiting at the
// before_apply_config hook. Safe to call even if no goroutine is waiting.
func ReleaseHangBeforeApplyConfig() {
	hooksMu.Lock()
	ch := hangGates["before_apply_config"]
	delete(hangGates, "before_apply_config")
	hooksMu.Unlock()
	if ch != nil {
		close(ch)
	}
}

// SetFaultErrorBeforeApplyConfig makes Start() return an error at the
// ApplyConfig hook without calling executor.ApplyConfig. Pass "" to clear.
func SetFaultErrorBeforeApplyConfig(msg string) {
	hooksMu.Lock()
	defer hooksMu.Unlock()
	if msg == "" {
		delete(errorMsgs, "before_apply_config")
	} else {
		errorMsgs["before_apply_config"] = msg
	}
}

// SetFaultPanicBeforeApplyConfig panics on the JNI-calling goroutine at the
// ApplyConfig hook. Start()'s defer recover() catches this and surfaces it as
// a Java exception. Pass "" to clear.
func SetFaultPanicBeforeApplyConfig(msg string) {
	hooksMu.Lock()
	defer hooksMu.Unlock()
	if msg == "" {
		delete(panicMsgs, "before_apply_config")
	} else {
		panicMsgs["before_apply_config"] = msg
	}
}

// SetFaultBackgroundPanic spawns a goroutine that panics after delayMs. The
// goroutine has NO recover() — it terminates the process unconditionally.
// Only call this in process-death recovery tests where the test runner is
// prepared for the process to exit. Pass msg="" to cancel a pending panic
// (safe only if called before the delay expires).
func SetFaultBackgroundPanic(msg string, delayMs int64) {
	bgPanicMu.Lock()
	bgPanicStr = msg
	bgPanicMu.Unlock()

	if msg == "" {
		return
	}

	go func() {
		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}
		// Re-read under lock: ClearAllFaults() may have run between the
		// sleep start and now.
		bgPanicMu.Lock()
		current := bgPanicStr
		bgPanicMu.Unlock()
		if current == msg {
			panic(current) // no recover — process terminates
		}
	}()
}

// ClearAllFaults removes all installed faults, releases all hang gates, and
// resets call counters. Call from test tearDown to isolate tests from each
// other.
func ClearAllFaults() {
	hooksMu.Lock()
	for _, ch := range hangGates {
		// Drain or close without double-close.
		select {
		case <-ch:
		default:
			close(ch)
		}
	}
	hangGates = map[string]chan struct{}{}
	hangDurs = map[string]time.Duration{}
	errorMsgs = map[string]string{}
	panicMsgs = map[string]string{}
	hooksMu.Unlock()

	bgPanicMu.Lock()
	bgPanicStr = ""
	bgPanicMu.Unlock()

	atomic.StoreInt32(&startCount, 0)
	atomic.StoreInt32(&stopCount, 0)
}

// GetStartCallCount returns how many times Start() has been entered since the
// last ClearAllFaults() or ResetCallCounts().
func GetStartCallCount() int32 { return atomic.LoadInt32(&startCount) }

// GetStopCallCount returns how many times Stop() has been entered since the
// last ClearAllFaults() or ResetCallCounts().
func GetStopCallCount() int32 { return atomic.LoadInt32(&stopCount) }

// ResetCallCounts zeroes both counters without clearing fault hooks.
func ResetCallCounts() {
	atomic.StoreInt32(&startCount, 0)
	atomic.StoreInt32(&stopCount, 0)
}

// ---------------------------------------------------------------------------
// Goroutine inventory (real implementation under veer_fault_inject)
// ---------------------------------------------------------------------------

// GoroutineSnapshot is a point-in-time capture of Go goroutine population.
// Exported as a gomobile-compatible struct (only primitive field types).
type GoroutineSnapshot struct {
	Count     int32  // runtime.NumGoroutine() at snapshot time
	Timestamp int64  // Unix milliseconds
	Stacks    string // full runtime.Stack output; empty when includeStacks=false
}

// TakeGoroutineSnapshot captures the current goroutine count and, optionally,
// the full stack dump of every goroutine. Stack dumps may be several hundred
// kilobytes; set includeStacks=true only when debugging a specific leak.
func TakeGoroutineSnapshot(includeStacks bool) *GoroutineSnapshot {
	s := &GoroutineSnapshot{
		Count:     int32(runtime.NumGoroutine()),
		Timestamp: time.Now().UnixMilli(),
	}
	if includeStacks {
		buf := make([]byte, 128*1024)
		n := runtime.Stack(buf, true)
		s.Stacks = string(buf[:n])
	}
	return s
}

// GoroutineDelta returns after.Count - before.Count. Positive means goroutines
// were created; negative means they exited. After a clean stop+cleanup cycle
// this should be ≤ 0.
func GoroutineDelta(before, after *GoroutineSnapshot) int32 {
	if before == nil || after == nil {
		return 0
	}
	return after.Count - before.Count
}
