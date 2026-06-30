// Package veercore is the gomobile-facing wrapper around the Mihomo (Clash Meta) core.
//
// Build with:
//   gomobile bind -target=android -androidapi 29 -o ../app/libs/libveer_core.aar .
//
// All exported functions recover from Go panics and surface them as Java exceptions
// so a misconfigured YAML cannot crash the host process.
package veercore

import (
	"errors"
	"fmt"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

// SocketProtector is implemented on the Kotlin side. It calls
// android.net.VpnService.protect(fd) so outbound sockets created by Mihomo
// bypass the tun interface and avoid a routing loop.
type SocketProtector interface {
	Protect(fd int32) bool
}

// Logger is implemented on the Kotlin side. Mihomo's internal log stream is
// forwarded here so Logcat gets the full Go-side picture; the methods map
// 1:1 to android.util.Log.{d,i,w,e}.
type Logger interface {
	Debug(msg string)
	Info(msg string)
	Warn(msg string)
	Error(msg string)
}

var (
	protector SocketProtector

	logMu     sync.Mutex
	logger    Logger
	logCancel chan struct{} // closed to stop the forwarder goroutine
)

// SetProtector is invoked once from Kotlin after the VpnService is up.
func SetProtector(p SocketProtector) {
	defer func() { _ = recover() }()
	protector = p
}

// SetLogger installs (or replaces) the Kotlin-side logger and starts the
// forwarder goroutine that pumps mihomo log events into it. Calling with a
// nil logger detaches the forwarder.
func SetLogger(l Logger) {
	defer func() { _ = recover() }()
	logMu.Lock()
	defer logMu.Unlock()

	// Tear down any previous forwarder so we never have two goroutines
	// racing to drain a single log subscription.
	if logCancel != nil {
		close(logCancel)
		logCancel = nil
	}
	logger = l
	if l == nil {
		return
	}

	sub := log.Subscribe()
	cancel := make(chan struct{})
	logCancel = cancel
	go forwardLogs(sub, cancel)
}

func forwardLogs(sub observable.Subscription[log.Event], cancel <-chan struct{}) {
	for {
		select {
		case <-cancel:
			return
		case ev, ok := <-sub:
			if !ok {
				return
			}
			deliver(ev)
		}
	}
}

func deliver(ev log.Event) {
	logMu.Lock()
	l := logger
	logMu.Unlock()
	if l == nil {
		return
	}
	defer func() { _ = recover() }() // never let a buggy Kotlin logger crash us
	switch ev.LogLevel {
	case log.DEBUG:
		l.Debug(ev.Payload)
	case log.INFO:
		l.Info(ev.Payload)
	case log.WARNING:
		l.Warn(ev.Payload)
	case log.ERROR:
		l.Error(ev.Payload)
	default:
		l.Info(ev.Payload)
	}
}

// Start initializes Mihomo from <homeDir>/<configName>. If tunFd >= 0 the
// parsed config's tun.device is overridden to "fd://<tunFd>" so Mihomo's
// inbound takes ownership of the Android VPN file descriptor.
func Start(homeDir string, configName string, tunFd int32) (err error) {
	incrStartCount() // no-op in production builds
	defer func() {
		if r := recover(); r != nil {
			buf := make([]byte, 4096)
			n := runtime.Stack(buf, false)
			err = fmt.Errorf("mihomo start panic: %v\n%s", r, buf[:n])
		}
	}()

	if configName == "" {
		configName = "base.yaml"
	}

	constant.SetHomeDir(homeDir)
	constant.SetConfig(filepath.Join(homeDir, configName))

	cfg, parseErr := executor.Parse()
	if parseErr != nil {
		return fmt.Errorf("parse config: %w", parseErr)
	}
	if cfg == nil {
		return errors.New("parse config: nil result")
	}

	if tunFd >= 0 && cfg.General != nil {
		cfg.General.Tun.Enable = true
		cfg.General.Tun.Device = "fd://" + strconv.Itoa(int(tunFd))
	}

	// triggerHook is a no-op in production builds (veer_noop_stubs.go).
	// In debug builds (veer_fault_inject.go) it may hang, return an error, or
	// panic on this goroutine — all before executor.ApplyConfig is called.
	if hookErr := triggerHook("before_apply_config"); hookErr != nil {
		return hookErr
	}

	executor.ApplyConfig(cfg, true)
	log.Infoln("mihomo started; home=%s tunFd=%d", homeDir, tunFd)
	return nil
}

// Stop gracefully shuts down the running core.
func Stop() (err error) {
	incrStopCount() // no-op in production builds
	defer func() {
		if r := recover(); r != nil {
			buf := make([]byte, 4096)
			n := runtime.Stack(buf, false)
			err = fmt.Errorf("mihomo stop panic: %v\n%s", r, buf[:n])
		}
	}()
	executor.Shutdown()
	log.Infoln("mihomo stopped")
	return nil
}

// ValidateConfig parses the config at <homeDir>/<configName> and builds
// Mihomo's internal data structures without starting any runtime goroutines.
// Returns nil if the config is valid; returns a descriptive error otherwise.
// Safe to call before Start() to separate config validity from runtime startup.
func ValidateConfig(homeDir string, configName string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			buf := make([]byte, 4096)
			n := runtime.Stack(buf, false)
			err = fmt.Errorf("ValidateConfig panic: %v\n%s", r, buf[:n])
		}
	}()
	if configName == "" {
		configName = "base.yaml"
	}
	constant.SetHomeDir(homeDir)
	constant.SetConfig(filepath.Join(homeDir, configName))
	cfg, parseErr := executor.Parse()
	if parseErr != nil {
		return fmt.Errorf("validate config: %w", parseErr)
	}
	if cfg == nil {
		return errors.New("validate config: nil result")
	}
	return nil
}

// Version returns a build identifier so the Kotlin layer can verify that the
// .aar it loaded matches the wrapper sources.
func Version() string {
	return "veer-core/0.1.2+phase1.2"
}
