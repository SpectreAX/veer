//go:build !veer_fault_inject

package veercore

// Production build stubs. All functions here are zero-cost no-ops that the
// Go compiler eliminates entirely. They exist so that veer_core.go can call
// triggerHook / incrStartCount / incrStopCount unconditionally without
// conditional compilation at each call site, and so that the gomobile-generated
// JNI surface exposes the same method names in both build variants (enabling
// Kotlin debug code to compile against the release .aar without undefined
// symbol errors).

func triggerHook(_ string) error { return nil }
func incrStartCount()            {}
func incrStopCount()             {}

func SetFaultHangBeforeApplyConfig(_ int64)       {}
func ReleaseHangBeforeApplyConfig()               {}
func SetFaultHangBeforeShutdown(_ int64)          {}
func ReleaseHangBeforeShutdown()                  {}
func SetFaultErrorBeforeApplyConfig(_ string)     {}
func SetFaultErrorOnceBeforeApplyConfig(_ string) {}
func SetFaultPanicBeforeApplyConfig(_ string)     {}
func SetFaultBackgroundPanic(_ string, _ int64)   {}
func ClearAllFaults()                             {}
func GetStartCallCount() int32                    { return 0 }
func GetStopCallCount() int32                     { return 0 }
func ResetCallCounts()                            {}

// GoroutineSnapshot mirrors the type defined in veer_fault_inject.go so that
// gomobile produces identical Java bindings in both build variants.
type GoroutineSnapshot struct {
	Count     int32
	Timestamp int64
	Stacks    string
}

// TakeGoroutineSnapshot returns a zeroed snapshot. Count == 0 is the sentinel
// the Kotlin layer uses to detect that the production .aar is loaded and skip
// goroutine-count assertions (see GoroutineInventory.isAvailable).
func TakeGoroutineSnapshot(_ bool) *GoroutineSnapshot {
	return &GoroutineSnapshot{}
}

func GoroutineDelta(_, _ *GoroutineSnapshot) int32 { return 0 }
