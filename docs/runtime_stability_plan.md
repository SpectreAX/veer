# Veer Runtime Stability Validation Plan

**Goal:** Validate Veer under realistic Android networking conditions. Synthetic fault injection
(`runtime_validation_harness.md`) validates invariants in a controlled environment. This plan
validates that those invariants hold under the pressure of real Android platform behavior:
network topology changes, power-management interference, OEM firmware variations, and
sustained operation over hours.

**Prerequisite reading:**
- `runtime_invariants.md` — invariants under test
- `runtime_nonrecoverable_states.md` — failure classification and restart criteria
- `process_isolation_architecture.md` — A2 target and its stability implications
- `runtime_validation_harness.md` — synthetic baseline (all harness tests must pass before
  this plan is executed)

---

## 1. Observability Infrastructure

### 1.1 Passive signals (always available)

| Signal | Collection command | Interpretation |
|---|---|---|
| VPN lifecycle logs | `adb logcat -s VeerVpnService` | EngineState transitions, teardown path taken |
| Go core logs | `adb logcat -s Veer-Core` | Mihomo internal events, DNS/proxy errors |
| Connectivity events | `adb shell dumpsys connectivity` | Underlying network changes |
| VPN service state | `adb shell dumpsys vpn` | Android VPN session active/revoked |
| Process RSS | `adb shell cat /proc/$(adb shell pidof com.yamax.veer)/status \| grep VmRSS` | Memory growth |
| Open fd count | `adb shell ls /proc/$(adb shell pidof com.yamax.veer)/fd \| wc -l` | fd stability |
| Goroutine count | `adb shell cat /proc/$(adb shell pidof com.yamax.veer)/status \| grep Threads` | OS thread count (proxy; not goroutine count) |
| Battery state | `adb shell dumpsys batterystats --charged` | Drain delta per scenario |
| Network interface stats | `adb shell cat /proc/$(adb shell pidof com.yamax.veer)/net/dev` | Packet counters on tun0 |

### 1.2 Mihomo REST API signals (available while core is running)

The REST API at `127.0.0.1:9090` is loopback-local and independent of underlying network
connectivity. These queries work from the host via `adb forward tcp:9090 tcp:9090`.

| Endpoint | Method | Signal |
|---|---|---|
| `/version` | GET | Core alive; null response triggers watchdog |
| `/connections` | GET | Active proxy connection count and age |
| `/traffic` | GET (WS) | Real-time upload/download byte rate |
| `/logs?level=info` | GET (WS) | Mihomo internal log stream |
| `/proxies` | GET | Proxy group health and latency |
| `/providers/rules` | GET | Rule provider last-updated timestamps |

### 1.3 Application-level signals (debug build + `veer_fault_inject` .aar)

| Signal | Source | Notes |
|---|---|---|
| EngineState trace | `PhaseTrace.peek()` | Every setState call with timestamp and caller |
| Goroutine count | `GoroutineInventory.take()` | Requires debug .aar; production returns 0 |
| Go call counters | `FaultInjector.startCallCount` / `.stopCallCount` | Count of Veercore.start/stop calls |

### 1.4 Collection harness

For multi-hour scenarios, collect signals at regular intervals using a background script:

```bash
#!/bin/bash
# stability_collect.sh — run on host while device is connected via ADB.
# Logs one sample per interval to stability_session_$SESSION_ID.tsv.

SESSION_ID=$(date +%Y%m%d_%H%M%S)
INTERVAL_S=60
OUT="stability_session_${SESSION_ID}.tsv"

echo -e "elapsed_s\tpid\tvmrss_kb\tfd_count\tengine_state\tconnections\ttun_rx_bytes\ttun_tx_bytes" > "$OUT"

START=$(date +%s)
while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    PID=$(adb shell pidof com.yamax.veer 2>/dev/null | tr -d '\r')
    [ -z "$PID" ] && { echo "Process not found at ${ELAPSED}s" >> "$OUT"; sleep "$INTERVAL_S"; continue; }

    VMRSS=$(adb shell "grep VmRSS /proc/$PID/status 2>/dev/null" | awk '{print $2}' | tr -d '\r')
    FD=$(adb shell "ls /proc/$PID/fd 2>/dev/null | wc -l" | tr -d '\r ')
    CONNECTIONS=$(adb shell "curl -s 127.0.0.1:9090/connections 2>/dev/null | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(len(d.get(\"connections\",[])))' \
        2>/dev/null" | tr -d '\r')
    NET=$(adb shell "grep tun /proc/$PID/net/dev 2>/dev/null | awk '{print \$2,\$10}'" | tr -d '\r')
    RX=$(echo "$NET" | awk '{print $1}')
    TX=$(echo "$NET" | awk '{print $2}')
    # EngineState is emitted to Logcat; extract the most recent one.
    STATE=$(adb logcat -d -s VeerVpnService 2>/dev/null \
        | grep -oP 'setState\(\K[^)]+' | tail -1 | tr -d '\r')

    echo -e "${ELAPSED}\t${PID}\t${VMRSS}\t${FD}\t${STATE}\t${CONNECTIONS}\t${RX}\t${TX}" >> "$OUT"
    sleep "$INTERVAL_S"
done
```

---

## 2. Metric Thresholds and Acceptance Criteria

These thresholds define the boundary between normal behaviour and an actionable regression.
Values are derived from Phase 1.1 architecture constraints; tighten them as empirical baselines
are established.

### 2.1 Memory

| Metric | Acceptable | Warning | Critical (immediate investigation) |
|---|---|---|---|
| RSS at Running steady-state | 80–120 MB | 120–160 MB | > 160 MB |
| RSS growth rate (first 2h) | ≤ 8 MB/h | 8–15 MB/h | > 15 MB/h |
| RSS growth rate (2h–8h) | ≤ 3 MB/h | 3–8 MB/h | > 8 MB/h |
| RSS growth rate (8h+) | ≤ 1 MB/h | 1–4 MB/h | > 4 MB/h |

Sustained growth beyond the Critical threshold indicates either a Mihomo connection-pool leak,
a Kotlin-side log buffer overflow (check `MihomoEngine._logs` replay count), or a goroutine
stack growth leak.

### 2.2 Goroutine count (debug build only)

| Metric | Acceptable | Warning | Critical |
|---|---|---|---|
| Goroutine count at Running steady-state | baseline + 0–4 | baseline + 5–8 | baseline + > 8 |
| Goroutine delta after 1 stop+start cycle | ≤ +2 | +3 to +5 | > +5 |
| Goroutine delta after 10 stop+start cycles | ≤ +4 | +5 to +10 | > +10 |

A positive goroutine delta that accumulates linearly with restart count is a leak (Scenarios
S3/S8 from `runtime_nonrecoverable_states.md`). A one-time delta of +2 after the first
start is expected (Mihomo background goroutines that take a few hundred milliseconds to
stabilize post-ApplyConfig).

### 2.3 File descriptors

| Metric | Acceptable | Action |
|---|---|---|
| fd count at Running steady-state | baseline + 0–3 | No action |
| fd count after stop+start cycle | ≤ baseline + 1 | No action |
| fd count trend after N cycles | stable (no linear growth) | No action |
| fd count growth of +1/cycle | tun fd dup leak | Treat as Critical; file bug |

### 2.4 EngineState stability

For a healthy session, the only expected state sequence after initial boot is:
```
Stopped → Starting → Running
```
Any further transition is an event to classify:

| Transition | Classification | SLA |
|---|---|---|
| Running → Error → Stopping → Stopped → Starting → Running | Transient fault, auto-recovery | Acceptable if < 1/hour |
| Running → Error → Stopping → Stopped (no restart) | Fault requires user action | Investigate root cause |
| Running → Stopping → Stopped (clean stop) | User-initiated or watchdog | Expected |
| Any state → Stopped without Stopping | Force-close timeout triggered | Investigate; may indicate hung Shutdown |
| Starting → Error (no subsequent Running) | Start failure | Investigate config/permission |

### 2.5 Watchdog triggers

| Rate | Classification |
|---|---|
| 0 / hour in steady-state | Normal |
| 1–2 / hour during network transitions | Acceptable; likely transient REST unreachability |
| 3+ / hour | Warning; Mihomo REST listener may be degraded |
| Consistent every poll cycle | Critical; executor may be hung |

### 2.6 Proxy connection success rate

Measured by sampling `/connections` and counting connections with `UploadTotal > 0` (successfully
used) vs total established. On a healthy session with active traffic:

| Rate | Classification |
|---|---|
| ≥ 97% | Healthy |
| 90–97% | Acceptable during network transitions |
| 80–90% | Warning; may indicate DNS or rule-engine degradation |
| < 80% | Critical |

### 2.7 Restart criteria

| Condition | Action |
|---|---|
| Single watchdog trigger | Auto-recover via stopSelf() → START_STICKY restart |
| 3 consecutive triggers within 5 minutes | Surface EngineState.Error; require user reconnect |
| Process killed by OS (OOM, Doze) | Auto-recover via START_STICKY (transparent if < 3s) |
| Stop() or Cleanup() timeout | **MANDATORY**: require process restart before next session |
| Hung shutdown goroutine detected (post-timeout, log present) | **MANDATORY**: process restart |
| Background goroutine panic | Automatic (OS terminates and restarts process) |

---

## 3. Scenario Specifications

---

### S1 — Long-Running Session (8-hour baseline)

**Purpose:** Establish steady-state baselines for all metrics. Detect slow leaks invisible in
short tests.

**Environment:**
- Physical device on Wi-Fi (stable, no interference)
- Screen off (normal use case); adaptive brightness and battery saver OFF
- Background apps: email, calendar, social feed — realistic background load
- Active traffic: 10–30 req/min via proxy (browsing, app refreshes)

**Procedure:**
1. Boot the device clean (restart, no other VPN sessions for 24h).
2. Record baseline: RSS, fd count, goroutine count (debug build), logcat position.
3. Start VPN. Await `EngineState.Running`.
4. Begin collection harness at 60s interval.
5. Generate traffic continuously via a background script:
   ```bash
   # On-device via adb shell, or via a test APK:
   while true; do curl -x socks5://127.0.0.1:7890 -s https://ip.sb > /dev/null; sleep 5; done
   ```
6. Run for 8 hours.
7. Stop VPN. Await `Stopped`.
8. Record final metrics.

**Expected EngineState transitions:**
```
Stopped → Starting → Running   (at T=0)
Running                         (T=0 through T=8h, no further transitions)
Running → Stopping → Stopped   (at T=8h, user-initiated)
```
Any transitions between initial Running and final stop are regressions to investigate.

**Acceptance criteria:**
- No unexpected EngineState transitions for 8 hours
- RSS growth ≤ 8 MB/h for first 2h, ≤ 3 MB/h thereafter
- fd count stable (± 3 over baseline)
- Goroutine delta ≤ 4 over session
- Zero watchdog triggers
- Proxy success rate ≥ 97%
- Log file at `filesDir/logs/veer_<date>.log` ≤ 20 MB (rolling retention working)

**Failure escalation:**
- Unexpected EngineState.Error: capture full Logcat + `/connections` dump + goroutine stacks
- Memory growth > Critical threshold: take heap dump via `adb shell am dumpheap com.yamax.veer /data/local/tmp/heap.hprof`

---

### S2 — Extended Session (24-hour)

**Purpose:** Detect leaks that only manifest over long periods. Verify rolling log retention.

**Extends S1** to 24 hours with the following additions:
- Mixed traffic: active during 8h, idle during remaining 16h (screen off, no user traffic)
- Log file rotation must occur: `veer_<yesterday>.log` and `veer_<today>.log` should both exist
- 3-day retention: files older than 3 days should be pruned (check on day 4)

**Additional acceptance criteria beyond S1:**
- Goroutine delta ≤ 6 over 24h (slightly wider tolerance for longer GC cycles)
- RSS growth in idle phase ≤ 1 MB/h
- No more than 2 watchdog triggers in any 1-hour window during the idle phase
- Log file directory size ≤ 60 MB (3 days × 20 MB cap)

---

### S3 — Wi-Fi to Cellular Handoff

**Purpose:** Verify that VPN tunnel survives an underlying network change without EngineState
degradation. Validate watchdog does not false-positive on temporary REST unavailability during
the transition.

**Architecture note:** The tun device is a kernel virtual interface; it does not bind to a
physical adapter. The Mihomo REST API (`127.0.0.1:9090`) is on the loopback interface, which
is unaffected by physical network changes. Mihomo's outbound proxy connections use sockets that
are created fresh per connection; each new socket gets `VpnService.protect(fd)` applied,
routing it through the new physical interface. The transition should be transparent at the
VPN layer.

**Procedure:**
1. Connect device to Wi-Fi. Start VPN. Await Running.
2. Begin active traffic stream.
3. Record: `T_start = now()`, note current underlying network from `dumpsys connectivity`.
4. Disable Wi-Fi on the device while cellular is available.
5. Record: `T_wifi_off = now()`.
6. Monitor: TCP connections through the proxy. Existing connections will break (expected —
   they were routed through the old socket). New connections should succeed.
7. Record: `T_traffic_restored = now()` (when the traffic stream recovers).
8. Measure: `recovery_latency = T_traffic_restored - T_wifi_off`.
9. Wait 5 minutes. Re-enable Wi-Fi.
10. Repeat 3 times.

**Expected EngineState transitions:**
```
Running   (throughout — no transitions expected)
```
If EngineState transitions to Error during the handoff, the watchdog fired on a transient
condition. Validate that the watchdog's 30-second poll interval provides adequate debounce
(a single `null` response during handoff should NOT fire the watchdog because the
next poll succeeds).

**Implemented mitigation (Phase 1.2 SI-01):** The watchdog uses a 2-retry
debounce (three consecutive failures total):
```kotlin
// In launchWatchdog():
var consecutiveFailures = 0
while (isActive && coreRunning) {
    val version = runCatching { MihomoRepository.get().version() }.getOrNull()
    if (version == null && coreRunning) {
        consecutiveFailures++
        if (consecutiveFailures >= 3) {  // 3 consecutive failures before triggering
            MihomoEngine.publishLifecycleLog("watchdog: 3 consecutive API failures — stopping")
            MihomoEngine.setState(EngineState.Error("watchdog: core API unreachable"))
            requestShutdown("watchdog failure")
            break
        }
    } else {
        consecutiveFailures = 0
    }
    delay(effectiveWatchdogIntervalMs)
}
```

**Acceptance criteria:**
- EngineState remains Running throughout all handoffs
- Traffic recovery latency ≤ 3 seconds per handoff
- No watchdog triggers
- Proxy success rate ≥ 90% (10% tolerance for in-flight connections broken by handoff)

**Instruments:**
- `dumpsys connectivity | grep "CONNECTED"` before and after each transition
- Packet loss monitoring: `ping -x 127.0.0.1` (loopback, should be 0% loss throughout)
- Proxy connection timing: log `curl -w "%{time_total}" ...` for each request

---

### S4 — Wi-Fi ↔ Cellular Rapid Switching (Stress)

**Purpose:** Stress-test the watchdog debounce path and verify no goroutine accumulation
from repeated network-change events.

**Procedure:**
1. Start VPN on Wi-Fi. Await Running.
2. Repeat 20 times with 30-second intervals:
   - Disable Wi-Fi → wait 15s → Re-enable Wi-Fi → wait 15s
3. After 20 cycles, stop VPN. Await Stopped.
4. Collect metrics.

**Expected EngineState transitions:**
```
Running   (throughout — 20 network changes must produce zero EngineState transitions)
Running → Stopping → Stopped   (at end)
```

**Acceptance criteria:**
- Zero EngineState transitions during switching cycles
- Goroutine delta over 20 cycles ≤ 4
- fd count stable
- Memory growth during switching ≤ 10 MB

**Failure mode:** If watchdog fires during switching, it indicates the loopback socket is
somehow bound to the physical interface (unexpected) or the Mihomo HTTP server goroutine
crashed. In either case, the goroutine stack dump at the time of failure is critical.

---

### S5 — Doze Mode and Background Restrictions

**Purpose:** Validate that `VeerVpnService` survives Android's Doze mode without being killed
by the power manager, and that the watchdog remains functional during Maintenance Windows.

**Doze behavior for VPN services:**
- `VeerVpnService` runs as a foreground service with `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`.
- Android documentation states that foreground services are generally exempt from Doze network
  restrictions, but NOT exempt from Doze on all OEMs (see §5 for OEM matrix).
- During Doze, the device may enter "light Doze" (limited network, timers deferred) or
  "deep Doze" (network suspended, all wakelock-independent work deferred).
- The tun device remains open during Doze: kernel VPN routing does not require a running
  userspace process to maintain the kernel-side routing table entries that were installed when
  `VpnService.Builder.establish()` was called.
- Loopback (`127.0.0.1`) is NOT subject to Doze network restrictions — it is an intra-device
  communication path. The watchdog should continue to succeed.

**Procedure:**
1. Fully charge device. Disconnect charger.
2. Start VPN. Await Running.
3. Lock screen (screen off). Wait for Doze entry (~1 hour on a stock device, or force via
   `adb shell dumpsys deviceidle force-idle`).
4. Confirm Doze active: `adb shell dumpsys deviceidle | grep "state=IDLE"`.
5. Wait 30 minutes inside Doze.
6. Exit Doze: `adb shell dumpsys deviceidle unforce`.
7. Unlock screen. Verify VPN still Running and traffic flows.

**Force-Doze shortcut for CI:**
```bash
adb shell dumpsys deviceidle enable deep
adb shell dumpsys deviceidle force-idle
sleep 120  # 2 minutes in forced Doze
adb shell dumpsys deviceidle unforce
adb shell dumpsys deviceidle disable
```

**Expected EngineState transitions:**
```
Running   (throughout Doze entry, Doze period, and Doze exit)
```
If watchdog fires during Doze, the loopback assumption is violated. Capture:
- `adb shell dumpsys deviceidle` at time of failure
- `adb shell netstat -an | grep 9090` — verify Mihomo's REST listener is still bound

**Acceptance criteria:**
- EngineState.Running maintained through full Doze cycle
- Zero watchdog triggers during Doze period
- Traffic resumes within 5 seconds of Doze exit
- No EngineState transition occurs during Maintenance Window (brief network access periods)

**If EngineState.Error occurs during Doze:**
Classify as OEM-specific issue (see §5). The kill came from the power manager, not from
Mihomo internals. Recovery via START_STICKY is expected, but the window between kill and
restart may leave the user without VPN coverage.

---

### S6 — Android Battery Optimization (OEM-Specific Kill Scenarios)

**Purpose:** Identify OEM-specific power management behaviors that kill VeerVpnService despite
it being a foreground VPN service. Quantify time-to-kill and recovery time.

**Background:** Several Android OEMs implement aggressive background process killing that
bypasses Android's foreground service protections:

| OEM | Behavior | Known issue |
|---|---|---|
| Xiaomi (MIUI/HyperOS) | "Battery Saver" may kill foreground services after 5–10 min screen-off | Requires "Autostart" permission + battery optimization exception |
| OPPO/OnePlus (ColorOS/OxygenOS) | "Smart Battery" kills non-whitelisted foreground services | Requires "Allow background activity" + battery exemption |
| Huawei (EMUI/HarmonyOS Android) | "Phone Manager" aggressive cleanup; particularly hostile to VPN | Requires Protected Apps list + ignore battery optimization |
| Samsung (One UI) | Generally respects foreground services; issues only with DeX or power saving mode | Enable "Allow background activity" in battery settings |
| Stock Android (Pixel, AOSP) | Respects foreground service guarantees | No special configuration needed |

**Procedure (per OEM):**
1. Enable battery optimization for Veer (simulate user who has NOT whitelisted the app).
2. Start VPN. Await Running.
3. Lock screen. Wait.
4. Record `T_kill` = time when EngineState first transitions away from Running.
5. Record `T_restart` = time when EngineState next reaches Running (START_STICKY restart).
6. Compute: `kill_latency = T_kill - start_time`, `restart_latency = T_restart - T_kill`.
7. Repeat with battery optimization disabled. Record the same metrics.

**Metrics to collect:**
- `kill_latency` (optimized vs unoptimized)
- `restart_latency`
- Whether START_STICKY restart actually fires (some OEMs suppress it)
- Whether the VPN notification disappears and reappears during restart
- User-visible gap in VPN coverage: `T_restart - T_kill`

**Acceptance criteria:**
- With battery optimization disabled: kill_latency = infinite (never killed)
- With battery optimization enabled (MIUI/ColorOS): document kill_latency; assert restart_latency ≤ 5s
- VPN coverage gap ≤ 10 seconds when battery optimization is enabled

**Recovery path:** If START_STICKY restart does not fire within 10 seconds, the OEM has
suppressed process restart. The user must manually reconnect. This is classified as a
configuration issue, not a code defect.

**Required documentation output:** For each OEM tested, produce:
```
OEM: Xiaomi Redmi Note 12 (MIUI 14.0.6)
Battery optimization: ENABLED
Kill latency: 8m 33s after screen lock
Restart fired: YES (START_STICKY)
Restart latency: 2.1s
VPN gap: 2.1s (acceptable)
Fix: Add "Autostart" permission + battery whitelist guidance in onboarding
```

---

### S7 — Suspend/Resume Cycles

**Purpose:** Validate that VPN tunnel survives device sleep/wake cycles without tun fd
invalidation or EngineState degradation.

**Background:** When Android suspends the device (deep sleep, not just screen off), the kernel
suspends all processes. File descriptors remain open; the tun device kernel object persists.
On resume, the process continues from where it was suspended. The Go runtime resumes its goroutine
scheduler. Mihomo's health check timers and connection pool may have stale state after a long
sleep.

**Procedure:**
1. Start VPN. Await Running.
2. Force device suspend: `adb shell input keyevent 26` (power button); verify screen off.
3. Wait 5 minutes.
4. Wake device: `adb shell input keyevent 26`.
5. Within 10 seconds of wake, verify: `curl 127.0.0.1:9090/version` returns a version string.
6. Verify: traffic flows through proxy.
7. Repeat 10 times with varying sleep durations (1 min, 5 min, 15 min, 30 min).

**Expected behavior:**
- EngineState remains Running across all suspend/resume cycles (process not killed during sleep)
- Mihomo REST API responds within 2 seconds of device wake
- Existing proxy connections may time out during sleep (TCP keepalive expiry) — new connections
  should succeed immediately

**Expected EngineState transitions:**
```
Running   (throughout all suspend/resume cycles)
```

**Acceptance criteria:**
- EngineState.Running maintained across all sleep cycles
- Mihomo API responsive within 2s of each wake
- Zero watchdog triggers per cycle

**OEM note:** On MIUI/ColorOS, the process may be killed during sleep (see S6). If so, record
the sleep duration at which kills start occurring.

---

### S8 — DNS Degradation

**Purpose:** Validate that Mihomo handles DNS server unreachability gracefully without
crashing the VPN service or corrupting the rule engine.

**Mihomo DNS architecture:** In fake-IP mode, Mihomo returns fake IP addresses from `198.18.0.0/15`
immediately for all DNS queries (without waiting for real resolution). Real DNS resolution happens
when a proxy connection is established, inside Mihomo's proxy goroutine chain. The fake-IP
mechanism means DNS degradation does NOT block the tun from accepting packets — it only affects
the success rate of proxy connections.

**Sub-scenarios:**

**S8a — DNS server timeout (unreachable nameserver):**
1. Start VPN. Verify traffic flows.
2. Configure a non-existent DNS server in `base.yaml` (e.g., `198.51.100.1`).
3. Reload config via `PUT /configs` REST API.
4. Attempt 20 connections through the proxy.
5. Expected: connections fail with DNS resolution error; VPN service stays Running.

**S8b — DNS SERVFAIL flood:**
1. Use a local DNS stub that returns SERVFAIL for all queries.
2. Verify: Mihomo handles SERVFAIL gracefully (returns connection error to client; does not panic).
3. Verify: EngineState remains Running; no watchdog triggers.

**S8c — Slow DNS (5s+ response time):**
1. Introduce 5-second DNS response latency.
2. Expected: Mihomo's DNS client respects its configured timeout; does not hold connections open
   indefinitely; goroutine count does not grow linearly with pending DNS queries.

**S8d — Recovery after DNS restoration:**
1. After S8a/S8b/S8c, restore a working DNS server.
2. Reload config.
3. Verify: connections succeed again; no residual error state.

**Acceptance criteria for all sub-scenarios:**
- EngineState.Running maintained throughout
- Zero watchdog triggers
- Goroutine count does not grow during DNS degradation
- Proxy success rate recovers to ≥ 97% within 30 seconds of DNS restoration

---

### S9 — Captive Portal Transition

**Purpose:** Validate behavior when the device connects to a captive portal network (hotel,
airport, enterprise Wi-Fi). Mihomo's outbound connections are redirected to the portal page.

**Architecture consideration:** With `VpnService.protect(fd)`, Mihomo's sockets bypass the VPN
tun and route through the physical network. On a captive portal network, the physical network
redirects all HTTP(S) traffic to the portal page. Mihomo's rule provider fetches, proxy health
checks, and any HTTP-based proxy connections all fail or receive unexpected redirects.

**Expected behavior:**
- Tun remains active; packets from Android apps arrive at Mihomo's tun reader goroutine.
- Proxy connections fail (captive portal redirect or TCP timeout).
- Rule provider refresh fails (HTTP redirect to portal page instead of rule YAML).
- Mihomo REST API continues to respond (loopback; captive portal does not affect loopback).
- VPN service stays Running; watchdog succeeds.

**Procedure:**
1. Start VPN on a known-good network. Verify traffic flows.
2. Connect to a captive portal network (or simulate via `adb shell iptables -A OUTPUT -j REJECT`
   for all non-loopback HTTP traffic).
3. Wait 5 minutes. Monitor: connections endpoint, logcat, EngineState.
4. Log into the captive portal (or remove iptables rule). Wait for network to open.
5. Verify: proxy connections succeed within 30 seconds of portal login.

**Acceptance criteria:**
- EngineState.Running throughout
- Zero watchdog triggers
- After portal login, proxy success rate ≥ 90% within 60 seconds
- No goroutine accumulation during captive portal period (failed proxy goroutines must exit)

**Known risk:** Rule provider refresh goroutines in Mihomo may accumulate if failed HTTP
requests are retried without a backoff cap. Monitor goroutine count during captive portal period.

---

### S10 — IPv6-Only Network

**Purpose:** Validate that the VPN service starts and functions on an IPv6-only network with
NAT64/DNS64.

**Architecture analysis:**
- VeerVpnService establishes the TUN with IPv4 (`172.19.0.1/30`) and IPv6
  (`fdfe:dcba:9876::1/126`) addresses. Mihomo uses the fd-backed `gvisor` stack
  (AAR tags `cmfa,with_gvisor`) for userspace TCP/UDP. Route installation is governed by the
  `BYPASS_LAN` flag (`VeerVpnService` companion, compile-time constant, currently `true`):
    - **`BYPASS_LAN = true`** — both address families use a default route minus
      local ranges: IPv4 RFC1918 (`10/8`, `172.16/12`, `192.168/16`), IPv4
      link-local (`169.254/16`), IPv4 multicast (`224/4`), IPv6 ULA
      (`fc00::/7`) and IPv6 link-local (`fe80::/10`). Two implementations are
      gated on `Build.VERSION.SDK_INT` because
      `VpnService.Builder.excludeRoute()` is API 33 (`TIRAMISU`):
        - **API 33+**: install `0.0.0.0/0` and `::/0`, then `excludeRoute()` the
          seven local prefixes.
        - **API 29–32**: install exact CIDR complements. IPv4 uses 40 routes:
          `0.0.0.0/5`, `8.0.0.0/7`, `11.0.0.0/8`,
          `12.0.0.0/6`, `16.0.0.0/4`, `32.0.0.0/3`, `64.0.0.0/2`, `128.0.0.0/3`,
          `160.0.0.0/5`, `168.0.0.0/8`, `169.0.0.0/9`, `169.128.0.0/10`,
          `169.192.0.0/11`, `169.224.0.0/12`, `169.240.0.0/13`,
          `169.248.0.0/14`, `169.252.0.0/15`, `169.255.0.0/16`,
          `170.0.0.0/7`, `172.0.0.0/12`, `172.32.0.0/11`, `172.64.0.0/10`,
          `172.128.0.0/9`, `173.0.0.0/8`, `174.0.0.0/7`, `176.0.0.0/4`, `192.0.0.0/9`,
          `192.128.0.0/11`, `192.160.0.0/13`, `192.169.0.0/16`, `192.170.0.0/15`,
          `192.172.0.0/14`, `192.176.0.0/12`, `192.192.0.0/10`, `193.0.0.0/8`,
          `194.0.0.0/7`, `196.0.0.0/6`, `200.0.0.0/5`, `208.0.0.0/4`,
          `240.0.0.0/4`.
          IPv6 uses 9 routes: `::/1`, `8000::/2`, `c000::/3`, `e000::/4`,
          `f000::/5`, `f800::/6`, `fe00::/9`, `fec0::/10`, `ff00::/8`.
          Neither fallback adds a family default route.
    - **`BYPASS_LAN = false`** — plain `0.0.0.0/0` and `::/0` defaults with no
      exclusions.
- **Exactly five IPv4 ranges bypass the tun under `BYPASS_LAN`: `10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` and `224.0.0.0/4`.**
  Other special-use ranges are handled as follows
  (each is a verifiable fact about the route table above, not an assumption):
    - `127.0.0.0/8` (loopback) — **not excluded; routed into the tun like any other
      non-excluded range** (via the `64.0.0.0/2` split route on 29–32, or the 33+ default).
    - `100.64.0.0/10` (CGNAT) — **intentionally tunneled, not bypassed.** CGNAT affects the
      carrier-assigned *source* address (e.g. China Mobile), not the destinations the
      device talks to; tunneling it is correct, and excluding it would risk leaking
      traffic meant for the proxy. It is not a LAN the device owns.
    - `169.254.0.0/16` (link-local) and `224.0.0.0/4` (multicast) — bypass the
      TUN so local discovery such as mDNS/SSDP can remain on the physical LAN.
- On an IPv6-only network, the underlying physical network has no IPv4 connectivity.
- Mihomo's proxy chain needs to reach proxy servers: if proxy servers have only IPv4 addresses,
  NAT64 is required. Android's DNS64 (built into the resolver) handles this transparently for
  apps, but Mihomo bypasses the system resolver (it uses its own DNS engine with `protect()`d sockets).
- Mihomo's DNS engine must use a DNS64-aware resolver or explicitly use IPv6 addresses for
  proxy servers.

**Procedure:**
1. Connect device to an IPv6-only Wi-Fi network (testbed with NAT64 + DNS64, or use a
   carrier network that supports IPv6-only with NAT64).
2. Verify IPv6 connectivity and absence of IPv4: `adb shell ip addr` should show no IPv4 on
   the physical interface; `adb shell curl -6 https://ipv6.google.com` should succeed.
3. Start VPN. Observe: does `Veercore.start()` complete? What do the logs say about DNS
   server initialization?
4. Verify: traffic through proxy succeeds or fails with a specific error.

**Expected failures and acceptable behavior:**
- If Mihomo's configured DNS server (e.g., `8.8.8.8`) is IPv4-only and no NAT64 is available:
  DNS queries from Mihomo fail → proxy connections fail → EngineState.Running BUT proxy
  success rate = 0%.
- If DNS64 is available: `8.8.8.8` resolves via `2001:db8::ffff:808:808` (NAT64) → DNS
  queries succeed → proxy connections to proxy servers with IPv4 addresses work via NAT64.
- The VPN service itself must start (EngineState.Running) even if proxy connections fail.

**Acceptance criteria:**
- EngineState.Running reached on IPv6-only network
- Zero watchdog triggers
- If NAT64 is available: proxy success rate ≥ 90%
- Logcat contains no `FATAL` or `SIGSEGV` entries

**Phase 2 migration note:** This scenario may also affect the SocketProtector cross-process
IPC path in A2 architecture. When veercore process calls protect(fd) via Binder, and the
underlying interface is IPv6-only, the AIDL transaction itself is loopback and unaffected.
But the protected socket's routing depends on the underlying network's IPv6 support.

---

### S11 — Rapid Connect/Disconnect Stress (100 Cycles)

**Purpose:** Stress-test the `engineMutex` serialization, `startAttempted` flag, and goroutine
teardown under rapid cycling. Complement the synthetic T-04 / T-18 harness tests with realistic
timing.

**Procedure:**
1. Record baseline: goroutine count, fd count, RSS.
2. Execute 100 cycles:
   ```kotlin
   repeat(100) {
       ctx.startForegroundService(VeerVpnService.startIntent(ctx))
       // Random delay: 100–2000ms (realistic user behavior)
       delay(Random.nextLong(100, 2000))
       ctx.startForegroundService(VeerVpnService.stopIntent(ctx))
       // Wait for Stopped before next cycle (bounded: 10s)
       awaitState(EngineState.Stopped::class.java, timeoutMs = 10_000)
   }
   ```
3. After 100 cycles, record final metrics.

**Expected EngineState transition pattern per cycle:**
```
Stopped → Starting → (Running OR Error) → Stopping → Stopped
```
The short delay between start and stop means some cycles may complete at Starting → Error
(if stop arrives while start is still in-progress). Both paths are valid; the critical
invariant is that each cycle ends at Stopped with exactly one start call and one stop call.

**Acceptance criteria:**
- All 100 cycles complete (no cycle stuck indefinitely)
- Total goroutine delta ≤ 10 across all 100 cycles
- fd count ≤ baseline + 2
- RSS growth ≤ 5 MB over 100 cycles
- Each `Veercore.start()` call is matched by exactly one `Veercore.stop()` call
- Zero cycles where the service remains in Starting or Stopping for > 10 seconds

---

### S12 — Process Reclaim Simulation

**Purpose:** Validate START_STICKY behavior and post-restart VPN re-establishment. Quantify
the user-visible VPN coverage gap from process death to re-establishment.

**S12a — Foreground forced kill:**
```bash
# Kill the process from ADB after VPN is running:
adb shell am force-stop com.yamax.veer
sleep 1
# Observe: does Android restart the service?
adb shell dumpsys activity services com.yamax.veer
```

**S12b — OOM simulation:**
```bash
# Trigger low-memory condition while VPN is running:
# (Requires a memory stress tool or running many other apps)
# ADB trigger: not directly possible; use monkey or a memory-allocating app.
# Observe the process being reclaimed by the OOM killer.
```

**S12c — `SIGKILL` from host:**
```bash
PID=$(adb shell pidof com.yamax.veer | tr -d '\r')
adb shell kill -9 $PID
# Observe restart behavior.
```

**Expected behavior for all sub-scenarios:**
1. Process terminates with no `onDestroy` call (SIGKILL is not catchable).
2. Android detects service death via Binder death notification to activity manager.
3. `START_STICKY` causes Android to restart `VeerVpnService.onStartCommand(intent=null)`.
4. The null intent falls through to `else -> bootCore()` (invariant §7.4).
5. Service re-establishes VPN with last-known config from `filesDir/mihomo/`.
6. EngineState transitions: (no states recorded during gap) → Starting → Running.

**Metrics:**
- `gap_duration = T_running_new - T_last_running_before_kill`
- Whether `START_STICKY` fires at all (OEM-dependent, see S6)
- Whether config files survived the process death (should: filesDir is persistent)

**Acceptance criteria:**
- START_STICKY fires within 5 seconds on stock Android (Pixel)
- VPN re-establishes (Running) within 10 seconds of process death on stock Android
- Config files intact: `base.yaml` and `ai_override.yaml` still valid after restart
- No goroutine accumulation in the restarted process compared to a clean first start

**Process-restart-required distinction:** S12 tests recovery from an *external* process kill
(OOM, user force-stop). This is different from the internal process-restart-required conditions
(hung Stop() or hung Cleanup()) defined in §2.7. Both result in process death; the difference
is that S12's recovery is handled automatically, while internal hang recovery requires a
deliberate user action (force-stop + re-open).

---

## 4. Expected EngineState Transition Matrix by Scenario

| Scenario | Expected transitions | Forbidden transitions | Recovery path |
|---|---|---|---|
| S1 Long-running | Boot only; none thereafter | Any transition during session | N/A |
| S2 Wi-Fi→cellular | None (tun is network-independent) | Error during handoff | Watchdog debounce (see §3 S3 note) |
| S3 Wi-Fi↔cellular | None | Error on any switch | Debounce fix |
| S4 Stress switching | None | Error on any cycle | Same |
| S5 Doze | None | Any kill by power manager | START_STICKY if OEM allows |
| S6 OEM battery kill | Running → (gap) → Starting → Running | None (kill is external) | START_STICKY; user whitelist |
| S7 Suspend/resume | None | Any state during sleep | N/A |
| S8 DNS degradation | None (proxy fails, service stays) | Error from DNS failure | No restart needed |
| S9 Captive portal | None | Error from HTTP redirect | No restart needed |
| S10 IPv6-only | Boot only | Start failure (config issue) | Config fix required |
| S11 Rapid cycling | Clean per-cycle sequence | Stuck Starting / Stopping | Investigate mutex |
| S12 Process reclaim | (gap) → Starting → Running | No restart (OEM suppress) | User reconnect |

---

## 5. OEM Test Device Matrix

Each scenario marked "P" = Pass required, "I" = Informational, "—" = Not applicable.

| Scenario | Pixel (Stock) | Samsung (One UI) | Xiaomi (MIUI 14) | OPPO (ColorOS 14) | Emulator |
|---|---|---|---|---|---|
| S1 Long-running 8h | P | P | P | P | I |
| S2 Wi-Fi→cellular | P | P | P | P | — |
| S3 Switching stress | P | P | I | I | — |
| S5 Doze | P | P | P | P | P |
| S6 Battery kill | P | P | P | P | — |
| S7 Suspend/resume | P | P | I | I | — |
| S8 DNS degradation | P | I | I | I | P |
| S9 Captive portal | P | I | I | I | — |
| S10 IPv6-only | P | I | I | I | — |
| S11 Rapid cycling | P | P | P | P | P |
| S12 Process reclaim | P | P | P | P | P |

**Minimum viable device set for Phase 1.1 sign-off:** Pixel (stock) + one MIUI device.
MIUI is the most aggressive OEM in terms of background kills and represents the highest-risk
failure class for a real-world user population.

---

## 6. Phase 1.2 Stability Improvements (Backlog)

Issues identified during scenario design that are out of scope for Phase 1.1 but must be
tracked:

| ID | Issue | Scenario | Priority |
|---|---|---|---|
| SI-01 | **Completed 2026-06-30:** watchdog requires 3 consecutive null responses; a successful probe resets the streak | S2, S3, S4 | High |
| SI-02 | Mihomo DNS engine does not use DNS64; IPv6-only proxy failures | S10 | Medium |
| SI-03 | Rule provider fetch goroutines may accumulate during captive portal | S9 | Medium |
| SI-04 | No app-level guidance for OEM battery optimization exemption | S6 | High |
| SI-05 | No VPN coverage gap metric exposed to UI (user unaware of reconnect) | S6, S12 | Medium |
| SI-06 | Log file cap not enforced per-line (a single long log line can exceed PIPE_BUF atomicity guarantee) | S1 | Low |
| SI-07 | Watchdog uses fixed poll interval; should back off on repeated failures | S2, S3 | Medium |
| SI-08 | **Completed 2026-07-28:** debug AAR includes `setFaultHangBeforeShutdown` / `releaseHangBeforeShutdown`; T-06 verifies the 5 s JNI stop latch preserves `Stopping → Error`. | F2, T-06 | Complete |
| SI-09 | **Completed 2026-07-29:** LAN bypass now excludes IPv6 ULA (`fc00::/7`) and link-local (`fe80::/10`) with `excludeRoute()` on API 33+ and an exact 9-prefix complement on API 29–32. Pure route-plan tests prove coverage and non-overlap; Android 16 LinkProperties showed both throw routes while VPN validation and proxy HTTP 204 remained healthy. | S10 | Complete |
| SI-10 | **Completed 2026-07-29:** IPv4 link-local (`169.254.0.0/16`) and multicast (`224.0.0.0/4`) now bypass the TUN. API 29–32 uses an exact 40-prefix complement; Android 16 exposed both throw routes and retained healthy proxy traffic. | S10 | Complete |

**SI-01, SI-08, SI-09 and SI-10 are complete.** The full Android instrumentation suite
passed on the Android 16 arm64 emulator with 16 tests, 0 failures and 0 skips.
The remaining acceptance work is to run the stability scenarios on the minimum
physical-device matrix in §5.13.

---

## 7. Regression Tracking

After each scenario run, produce a one-page result sheet:

```
Scenario: S1 — Long-Running 8h
Date: 2026-05-25
Device: Pixel 9 Pro (Android 16, stock)
Build: veer-core/0.1.1+phase1.1 (debug .aar)

Results:
  Session duration: 8h 02m 14s
  Unexpected EngineState transitions: 0
  Watchdog triggers: 0
  RSS at start: 98 MB
  RSS at end: 124 MB  (+26 MB over 8h = 3.25 MB/h)  [PASS: ≤ 8 MB/h first 2h, ≤ 3 MB/h after]
  Goroutine delta: +2  [PASS: ≤ 4]
  fd delta: 0  [PASS]
  Proxy success rate: 98.7%  [PASS]
  Log file size: 14.2 MB  [PASS]

Regressions vs previous run:
  None.

Open issues:
  None.
```

Store all result sheets in `docs/stability_results/` with filename
`S<N>_<YYYY-MM-DD>_<device>.md`. Maintain a one-line summary table in
`docs/stability_results/INDEX.md` so regressions are visible across runs.
