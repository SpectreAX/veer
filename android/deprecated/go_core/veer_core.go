// Package veercore is the gomobile-facing wrapper around the Mihomo (Clash Meta) core.
//
// Build with:
//
//	gomobile bind -target=android -androidapi 29 -o ../app/libs/libveer_core.aar .
//
// All exported functions recover from Go panics and surface them as Java exceptions
// so a misconfigured YAML cannot crash the host process.
package veercore

import (
	"errors"
	"fmt"
	"net/netip"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/transport/gun"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
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

	logMu       sync.Mutex
	logger      Logger
	logSub      observable.Subscription[log.Event]
	logConfigMu sync.Mutex
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
	logConfigMu.Lock()
	defer logConfigMu.Unlock()

	logMu.Lock()
	logger = l
	logMu.Unlock()

	if l == nil {
		if logSub != nil {
			// Unsubscribe rather than merely stopping the reader. Mihomo's
			// Observable retains every subscription; an unread 200-event buffer
			// eventually fills and blocks its global log channel, which can in
			// turn block Start/Stop on any log statement.
			log.UnSubscribe(logSub)
			logSub = nil
		}
		return
	}

	// A replacement Kotlin logger only changes the delivery target. Keep the
	// single live subscription and reader across in-process Stop/Start cycles.
	if logSub != nil {
		return
	}
	sub := log.Subscribe()
	logSub = sub
	go forwardLogs(sub)
}

func forwardLogs(sub observable.Subscription[log.Event]) {
	for ev := range sub {
		deliver(ev)
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

// closeEmbeddedListeners closes the inbound sockets that executor.Shutdown
// deliberately leaves to process exit. Veer keeps the Go runtime alive across
// VPN start/stop cycles, so leaving these listeners open retains their accept
// goroutines and any sessions accepted just before TUN teardown.
func closeEmbeddedListeners() {
	// Close TUN first. A gVisor TCP handshake already in progress can otherwise
	// finish after the tracker scan and create a connection that escapes this
	// shutdown cycle.
	listener.ReCreateTun(LC.Tun{}, tunnel.Tunnel)
	listener.PatchInboundListeners(nil, tunnel.Tunnel, true)
	listener.PatchTunnel(nil, tunnel.Tunnel)
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	listener.ReCreateTuic(LC.TuicServer{}, tunnel.Tunnel)
}

// Start initializes Mihomo from <homeDir>/<configName>. If tunFd >= 0 the
// parsed config's tun.file-descriptor is set to a dup of tunFd so Mihomo's
// sing-tun inbound owns a distinct descriptor from ParcelFileDescriptor.
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

	dupFd := -1
	handedToRuntime := false
	defer func() {
		if dupFd >= 0 && !handedToRuntime {
			_ = syscall.Close(dupFd)
		}
	}()

	if tunFd >= 0 && cfg.General != nil {
		var dupErr error
		dupFd, dupErr = syscall.Dup(int(tunFd))
		if dupErr != nil {
			return fmt.Errorf("dup tun fd: %w", dupErr)
		}
		cfg.General.Tun.Enable = true
		cfg.General.Tun.Device = ""
		cfg.General.Tun.FileDescriptor = dupFd
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.Inet4Address = []netip.Prefix{netip.MustParsePrefix("172.19.0.1/30")}
		cfg.General.Tun.Inet6Address = []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}
	}

	// triggerHook is a no-op in production builds (veer_noop_stubs.go).
	// In debug builds (veer_fault_inject.go) it may hang, return an error, or
	// panic on this goroutine — all before executor.ApplyConfig is called.
	if hookErr := triggerHook("before_apply_config"); hookErr != nil {
		return hookErr
	}

	handedToRuntime = dupFd >= 0
	hub.ApplyConfig(cfg)
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
	// Prevent new packets from creating trackers while shutdown is draining the
	// current runtime. executor.Shutdown() only closes listeners; it does not
	// close active TCP/UDP trackers first. With the gVisor TUN stack that can
	// leave stack.Close() waiting indefinitely for live endpoints, especially
	// while URL-test health checks are still running just after startup.
	tunnel.OnSuspend()
	// Stop accepting new local proxy sessions before draining providers and
	// trackers. Mihomo's standalone binary relies on process exit for these
	// sockets, but Veer's embedded runtime must release them explicitly.
	closeEmbeddedListeners()
	// Mihomo's executor.Shutdown() intentionally only owns listeners, iptables,
	// and fake-IP persistence. In a long-lived Android process the compatible
	// providers created for url-test/fallback groups would otherwise survive a
	// Stop/Start cycle until a later GC finalizer runs. Their health-check
	// contexts keep dialing through the old runtime and can stall the next
	// ApplyConfig. Close them explicitly before draining trackers/listeners.
	for _, proxyProvider := range tunnel.Providers() {
		if closer, ok := proxyProvider.(interface{ Close() error }); ok {
			_ = closer.Close()
		}
	}
	for _, ruleProvider := range tunnel.RuleProviders() {
		if closer, ok := ruleProvider.(interface{ Close() error }); ok {
			_ = closer.Close()
		}
	}
	// Drain connections after TUN and provider jobs have stopped, but before
	// their underlying proxy transports are released.
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		_ = tracker.Close()
		return true
	})
	// Proxy adapters can own resources independently of their provider. QUIC
	// based protocols such as Hysteria2 keep a client transport and hop-loop
	// alive until ProxyAdapter.Close is called; provider.Close only cancels the
	// provider's fetch and health-check jobs.
	for _, proxy := range tunnel.Proxies() {
		_ = proxy.Close()
	}
	for _, proxyProvider := range tunnel.Providers() {
		for _, proxy := range proxyProvider.Proxies() {
			_ = proxy.Close()
		}
	}
	// A provider health check can race with the proxy-map walk above after it
	// has already obtained a Gun transport. Close the process-wide registry as
	// the final generation barrier so no orphaned HTTP/2 read loop survives.
	gun.CloseAllTransports()
	// Close pooled DNS transports (including HTTP/2) that are not represented
	// by statistic trackers. The embedded runtime must make this a synchronous
	// generation barrier; upstream's asynchronous ResetConnection can otherwise
	// overlap the next ApplyConfig and retain old DoH keep-alive loops.
	dns.CloseAllDoHClients()
	resolver.ResetConnectionSync()
	// Debug builds can pause here so Android instrumentation verifies that the
	// JNI stop latch reports a non-recoverable timeout. This is a no-op in
	// production builds.
	if hookErr := triggerHook("before_shutdown"); hookErr != nil {
		return hookErr
	}
	executor.Shutdown()
	// executor.Shutdown does not own the external controller. ReCreateServer
	// with an empty config closes any existing HTTP/TLS/Unix controller listeners.
	route.ReCreateServer(&route.Config{})
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

// ReloadRules parses the materialised config and swaps only Mihomo's rule
// table. Android embed mode intentionally disables PUT /configs, and applying
// the whole on-disk config would destroy the runtime-injected TUN fd.
func ReloadRules(homeDir string, configName string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			buf := make([]byte, 4096)
			n := runtime.Stack(buf, false)
			err = fmt.Errorf("ReloadRules panic: %v\n%s", r, buf[:n])
		}
	}()
	if configName == "" {
		configName = "base.yaml"
	}
	cfg, parseErr := executor.ParseWithPath(filepath.Join(homeDir, configName))
	if parseErr != nil {
		return fmt.Errorf("reload rules: parse config: %w", parseErr)
	}
	if cfg == nil {
		return errors.New("reload rules: nil config")
	}
	tunnel.UpdateRules(cfg.Rules, cfg.SubRules, cfg.RuleProviders)
	log.Infoln("mihomo rules reloaded; count=%d", len(cfg.Rules))
	return nil
}

// UpdateSystemDNS replaces Mihomo's Android system-resolver generation after
// ConnectivityManager reports new LinkProperties. The comma-separated values
// are already normalized as host:port pairs by the Kotlin network monitor.
// Passing an empty string clears the resolver until an underlying network
// becomes available again.
func UpdateSystemDNS(servers string) {
	defer func() { _ = recover() }()
	var values []string
	for _, value := range strings.Split(servers, ",") {
		if value = strings.TrimSpace(value); value != "" {
			values = append(values, value)
		}
	}
	applySystemDNS(values)
	resolver.ClearCache()
	resolver.ResetConnectionSync()
	log.Infoln("Android system DNS updated; count=%d", len(values))
}

// TrafficStats is the small, allocation-light runtime snapshot consumed by
// the Android dashboard. Reading these counters in-process avoids asking the
// REST controller to materialize and JSON-encode every active connection just
// to display three numbers.
type TrafficStats struct {
	UploadTotal       int64
	DownloadTotal     int64
	ActiveConnections int32
}

// GetTrafficStats reads Mihomo's process-wide statistic manager directly.
// Total() uses atomic counters. Range() walks the live tracker map without
// constructing the TrackerInfo objects returned by the REST /connections API.
func GetTrafficStats() (stats *TrafficStats) {
	defer func() {
		if recover() != nil {
			stats = &TrafficStats{}
		}
	}()

	up, down := statistic.DefaultManager.Total()
	var active int32
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		active++
		return true
	})
	return &TrafficStats{
		UploadTotal:       up,
		DownloadTotal:     down,
		ActiveConnections: active,
	}
}

// DashboardRoutingStats contains only the routing fields rendered by the
// Android home screen. It deliberately excludes the full proxy tree and delay
// history returned by the REST /proxies endpoint.
type DashboardRoutingStats struct {
	CoreRunning  bool
	Mode         string
	Policy       string
	SelectedNode string
	NodeDelayMs  int32
}

// GetDashboardRoutingStats resolves the current selector chain in-process.
// defaultPolicy is the profile's main policy group; global mode always uses
// Mihomo's built-in GLOBAL selector.
func GetDashboardRoutingStats(defaultPolicy string) (stats *DashboardRoutingStats) {
	stats = &DashboardRoutingStats{NodeDelayMs: -1}
	defer func() {
		if recover() != nil {
			stats = &DashboardRoutingStats{NodeDelayMs: -1}
		}
	}()

	proxies := tunnel.Proxies()
	stats.CoreRunning = len(proxies) > 0
	stats.Mode = tunnel.Mode().String()
	if !stats.CoreRunning {
		return stats
	}

	policy := defaultPolicy
	if stats.Mode == tunnel.Global.String() {
		policy = "GLOBAL"
	}
	if _, exists := proxies[policy]; !exists {
		if _, exists = proxies["GLOBAL"]; exists {
			policy = "GLOBAL"
		} else {
			names := make([]string, 0, len(proxies))
			for name, proxy := range proxies {
				if proxy.Type() == constant.Selector {
					names = append(names, name)
				}
			}
			sort.Strings(names)
			if len(names) > 0 {
				policy = names[0]
			}
		}
	}
	stats.Policy = policy

	currentName := policy
	visited := make(map[string]struct{})
	for currentName != "" {
		if _, seen := visited[currentName]; seen {
			break
		}
		visited[currentName] = struct{}{}
		current, exists := proxies[currentName]
		if !exists {
			break
		}
		stats.SelectedNode = currentName
		selected, isGroup := current.Adapter().(interface{ Now() string })
		if !isGroup {
			history := current.DelayHistory()
			if len(history) > 0 {
				delay := history[len(history)-1].Delay
				if delay > 0 {
					stats.NodeDelayMs = int32(delay)
				}
			}
			break
		}
		currentName = selected.Now()
	}
	return stats
}

// Version returns a build identifier so the Kotlin layer can verify that the
// .aar it loaded matches the wrapper sources.
func Version() string {
	return "veer-core/0.1.9+mihomo-1.19.29.e26714a.cmfa.gvisor"
}
