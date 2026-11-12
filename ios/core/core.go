// Package main wraps the pinned, unmodified Mihomo core for the iOS Simulator prototype.
//
// LICENCE: linking Mihomo (GPL-3.0) into an app makes a GPL combined work. The owner approved
// this only for the undistributed iOS prototype; the macOS rule "never link Mihomo" is unchanged.
//
// The core runs in-process: Start parses the YAML and applies it with the same calls the mihomo
// binary makes (executor.Parse + hub.ApplyConfig), so the listeners and the external-controller
// come from the config. Stop applies an empty config, which closes every listener and the
// controller, then calls executor.Shutdown, so Start can run again in the same process.
package main

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/config"
	mc "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// stoppedConfig has no ports, no controller, no DNS and no TUN. Applying it closes everything
// the previous config opened without touching geodata or the cache file.
const stoppedConfig = "mode: direct\nlog-level: warning\nprofile:\n  store-selected: false\n"

const (
	readyTimeout = 5 * time.Second
	closeTimeout = 3 * time.Second
)

var (
	mu             sync.Mutex
	running        bool
	controllerAddr string // dialable host:port of the running external-controller, or ""
)

func init() {
	// Embed mode removes /restart and /upgrade (core, geo) from the controller: both would
	// exec or overwrite the host app's executable.
	route.SetEmbedMode(true)
}

func coreVersion() string { return mc.Version }

func validate(yaml []byte) (err error) {
	defer recoverInto(&err)
	if len(yaml) == 0 {
		return errors.New("configuration is empty")
	}
	mu.Lock()
	defer mu.Unlock()
	// Same call as `mihomo -t`: parse only, nothing is applied or started.
	_, err = executor.ParseWithBytes(yaml)
	return err
}

func start(homeDir, configPath string) (err error) {
	defer recoverInto(&err)
	mu.Lock()
	defer mu.Unlock()
	if running {
		return errors.New("core is already running; call VeerCoreStop first")
	}
	if !filepath.IsAbs(homeDir) || !filepath.IsAbs(configPath) {
		return fmt.Errorf("home dir and config path must be absolute (got %q, %q)", homeDir, configPath)
	}
	if err := os.MkdirAll(homeDir, 0o755); err != nil {
		return fmt.Errorf("create home dir: %w", err)
	}
	// Checked here because config.Init would silently write a default config instead.
	if _, err := os.Stat(configPath); err != nil {
		return fmt.Errorf("config file: %w", err)
	}
	mc.SetHomeDir(homeDir)
	mc.SetConfig(configPath)
	if err := config.Init(homeDir); err != nil {
		return err
	}
	cfg, err := executor.Parse()
	if err != nil {
		return err
	}
	// The prototype never opens a TUN device, whatever the profile says.
	cfg.General.Tun.Enable = false

	hub.ApplyConfig(cfg)
	running = true
	controllerAddr = dialAddr(cfg.Controller.ExternalController)

	if err := checkListeners(cfg); err != nil {
		stopLocked()
		return err
	}
	if controllerAddr != "" {
		if err := waitControllerUp(controllerAddr); err != nil {
			stopLocked()
			return err
		}
	}
	return nil
}

// Embed mode removes PUT/PATCH /configs from the controller, so a mode switch and a config
// reload come through here instead, with the same calls those handlers make.

func setMode(mode string) (err error) {
	defer recoverInto(&err)
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return errors.New("core is not running")
	}
	m, ok := tunnel.ModeMapping[strings.ToLower(mode)]
	if !ok {
		return fmt.Errorf("unknown mode %q", mode)
	}
	tunnel.SetMode(m)
	return nil
}

// reload re-reads the config file and applies it like PUT /configs (not forced: unchanged
// listeners stay up). The controller address cannot change while running.
func reload(configPath string) (err error) {
	defer recoverInto(&err)
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return errors.New("core is not running")
	}
	if !filepath.IsAbs(configPath) {
		return fmt.Errorf("config path must be absolute (got %q)", configPath)
	}
	cfg, err := executor.ParseWithPath(configPath)
	if err != nil {
		return err
	}
	cfg.General.Tun.Enable = false
	if dialAddr(cfg.Controller.ExternalController) != controllerAddr {
		return errors.New("external-controller changed; stop and start the core instead")
	}
	executor.ApplyConfig(cfg, false)
	return checkListeners(cfg)
}

func stop() {
	defer func() { _ = recover() }()
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if !running {
		return
	}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
	if cfg, err := executor.ParseWithBytes([]byte(stoppedConfig)); err == nil {
		hub.ApplyConfig(cfg) // closes inbound listeners, DNS server and the controller
	}
	executor.Shutdown()
	if controllerAddr != "" {
		waitControllerDown(controllerAddr)
	}
	controllerAddr = ""
	running = false
}

// checkListeners turns listen errors, which Mihomo only logs, into a Start error.
func checkListeners(cfg *config.Config) error {
	ports := listener.GetPorts()
	want := []struct {
		name      string
		want, got int
	}{
		{"mixed-port", cfg.General.MixedPort, ports.MixedPort},
		{"port", cfg.General.Port, ports.Port},
		{"socks-port", cfg.General.SocksPort, ports.SocksPort},
	}
	for _, p := range want {
		if p.want != 0 && p.got != p.want {
			return fmt.Errorf("%s %d failed to listen (see core log)", p.name, p.want)
		}
	}
	return nil
}

// dialAddr maps the configured listen address to one this process can connect to.
func dialAddr(addr string) string {
	if addr == "" {
		return ""
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return ""
	}
	switch host {
	case "", "0.0.0.0", "*":
		host = "127.0.0.1"
	case "::":
		host = "::1"
	}
	return net.JoinHostPort(host, port)
}

// waitControllerUp returns once the controller answers HTTP. route.ReCreateServer starts it in a
// goroutine and only logs a listen error, so Start would otherwise return before it is usable.
func waitControllerUp(addr string) error {
	client := &http.Client{
		Timeout:   500 * time.Millisecond,
		Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true},
	}
	deadline := time.Now().Add(readyTimeout)
	for time.Now().Before(deadline) {
		resp, err := client.Get("http://" + addr + "/")
		if err == nil {
			_ = resp.Body.Close()
			return nil // any status, including 401, means the server is serving
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("external-controller %s did not start within %s (see core log)", addr, readyTimeout)
}

func waitControllerDown(addr string) {
	deadline := time.Now().Add(closeTimeout)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err != nil {
			return
		}
		_ = c.Close()
		time.Sleep(50 * time.Millisecond)
	}
}

func recoverInto(err *error) {
	if r := recover(); r != nil {
		*err = fmt.Errorf("core panic: %v", r)
	}
}
