# Veer Android implementation status

Last updated: 2026-07-30.

## Implemented

- Android application (`com.yamax.veer`, minSdk 29) using Compose and Material 3
- Mihomo v1.19.29 gomobile runtime with the required `cmfa,with_gvisor` build tags
- Android-owned TUN fd handoff, socket protection, geo assets, local controller,
  serialized start/stop, stop timeouts, and watchdog
- Watchdog debounce: shutdown only after three consecutive failed probes (SI-01)
- Clash profile import from SAF file picker, pasted YAML, and HTTPS subscription
- Profile validation, normalization, atomic persistence, activation, refresh,
  rename, details, and deletion
- Android-safe runtime config generation with fixed TUN addresses and preserved
  DNS pollution fallback policy; local GeoIP data is required before startup
- AI natural-language routing for persistent site/service rules and live
  Selector switching, with runtime-context validation against real Mihomo
  groups and nodes
- Low-latency switching with fresh delay probes, safe fallback, repeated-command
  de-duplication, and protection against oscillating automatic groups
- Region-aware replacement of unavailable concrete nodes (Chinese, flag,
  English, and common region-code naming)
- Subscription metadata-node filtering for new imports plus migration of
  already-saved runtime configs, preventing quota/expiry rows from entering
  URLTest and Fallback groups
- Cross-profile AI rule compatibility filtering: rules that reference nodes or
  groups absent from the newly activated subscription are skipped at runtime
  instead of making Mihomo reject the entire configuration
- Profile-scoped AI rule persistence: each imported profile owns an independent
  rule file, legacy global rules migrate once to the active profile, and deleting
  a profile also deletes its rule scope
- Transactional live profile switching with serialized stop/activate/start,
  terminal-state timeouts, safe startup recovery, and repeated-tap protection
- In-process Veercore restart hardening: providers, trackers, listeners, and TUN
  are drained explicitly; the Mihomo logger uses one correctly unsubscribed
  observable subscription instead of leaking a blocking subscriber per restart
- Last Known Good snapshots and transactional rollback: every profile that
  reaches `Running` is snapshotted independently, failed target startup is
  drained to `Stopped`, the snapshot is restored, and the original failure
  stage/result is persisted without credentials
- Profile-scoped AI rule management UI with health states, enable/disable,
  policy rebinding, deletion, manual reapply, and live Veercore rule reload
- Live node and proxy-group UI backed by Mihomo controller snapshots, with
  region/health/delay display, manual Selector changes, per-node probes, and
  fresh lowest-latency automatic selection
- Live connection overview with VPN/controller/Internet separation, real
  Mihomo-routed exit IPv4/IPv6 and region, resolved default policy/node,
  latency, traffic, active connections, and loaded AI-rule count
- Versioned schema-1 AI plans with 1–8 ordered operations, legacy single-intent
  compatibility, per-operation execution feedback, and explicit partial-failure
  position reporting
- Atomic AI-plan execution with full preflight, one batch rule write/reload,
  serialized commits, original rule/Selector snapshots, and reverse rollback
  after injected post-reload or post-switch failures
- Conservative offline-first local plan parsing for domain direct/reject,
  healthy region routing, and live lowest-latency switching, with ambiguous
  commands falling back to the LLM
- Layered network diagnostics across physical connectivity, Android VPN/TUN,
  Mihomo controller/DNS/runtime rules, resolved node, proxy exit, and target
  site, with root-cause classification and skipped downstream checks
- Debounced proxy-exit auto recovery with bounded healthy-candidate probing,
  last-healthy preference, original Selector restoration, rule-aware
  suppression, and non-destructive degraded retry when recovery is exhausted
- Queued START handling across an in-flight shutdown, with full native/TUN
  drainage before the requested replacement runtime is started
- WorkManager-backed 24-hour subscription refresh with connected-network
  constraints, exponential retry, validation-before-persist, safe staging while
  VPN is running, next-start adoption, bounded history, and config diff summaries
- Subscription quota metadata and profile UI, Android Keystore AES-GCM API-key
  storage with plaintext migration, removal of build-time embedded keys, and
  centralized credential/URL redaction for Logcat, disk, UI, and exports
- Complete 14-case Android lifecycle fault matrix, including release-controlled
  start/stop JNI hangs, panic and startup-failure cleanup, concurrent commands,
  late callbacks, restart goroutine stability, and observable terminal states
- Late JNI-start drainage after the outer stop timeout: TUN closes on schedule,
  then the returning start coroutine performs a mandatory serialized native
  cleanup so no Go executor survives into the next connection
- Non-recoverable JNI-stop timeout preservation: `Stopping → Error` is no longer
  overwritten by `Stopped`, preventing unsafe same-process reconnect
- Explicit requested-region enforcement before LLM execution, preventing a
  missing UK/JP/etc. node from being silently substituted with another region
- Canonical service-to-geosite normalization (`DisneyPlus` → `disney`,
  `ChatGPT` → `openai`) while preserving other safe tags such as `telegram`
- Release hardening with Android backup disabled, R8/resource shrinking,
  gomobile JNI preservation, SnakeYAML reflection preservation, mapping output,
  and Android App Bundle generation
- Context-aware home operation flow with one primary action, first-import
  auto-activation, sequential notification/VPN permission handling, collapsible
  encrypted API-key management and logs, and inline AI readiness/result feedback
- One-tap latency probing across all unique leaf nodes with bounded concurrency,
  live progress, cross-group result propagation, operation locking, and no
  implicit selector mutation
- In-service one-tap fast reconnect that keeps the serialized native teardown
  contract while skipping Android's delayed service-destruction boundary
- Determinate home-screen startup progress driven by five real VPN-service
  milestones (config, geo data, validation, TUN, and Mihomo runtime), with no
  timer-based fake progress and automatic reset outside `Starting`
- Explicit AI-rule route summaries and highlighted exit-direction cards, showing
  service/domain traffic as `source → policy or node` instead of an ambiguous
  matcher-only title
- Dedicated `:veercore` process for VpnService, TUN ownership and all gomobile
  lifecycle calls, with bounded same-UID IPC for state, counters, routes, logs
  and rule reload
- Cross-process desired-state recovery: UI death leaves the tunnel untouched;
  unexpected replacement of an observed Running core PID triggers one safe
  restart, while explicit stop cannot be mistaken for a crash
- Event-driven Dashboard refresh with one-second traffic-only IPC, immediate
  mutation invalidation, 30-second Internet/exit probes and no background UI
  polling
- Property-gated Release ABI splits plus one-command packaging for arm64-v8a,
  armeabi-v7a, x86_64, Universal APK, AAB, deterministic versioned names and a
  self-verified SHA-256 manifest. Normal Debug output remains a single APK
- External-only Release signing through user Gradle properties or environment
  variables, with incomplete configuration rejected and an optional CI gate
  that refuses every unsigned artifact
- Symmetric LAN bypass for IPv4 RFC1918/link-local/multicast plus IPv6 ULA and
  link-local destinations. API 33+ uses seven framework throw routes; API
  29–32 uses exact IPv4/IPv6 CIDR complements defined by one host-testable
  route policy
- Per-app VPN routing with all-apps, selected-only and bypass-selected modes;
  atomic cross-process persistence, searchable app/icon UI, unavailable-app
  handling, empty allow-list fail-safe and automatic fast reconnect
- Physical-device lifecycle hardening: start generations and
  `stopSelfResult(startId)` prevent an old service stop from terminating a
  queued replacement runtime; native calls remain serialized through one
  stable executor
- Embedded-core transport cleanup for Android: request-scoped URL tests,
  bounded raw dials, permanently closed old-generation DoH clients, and
  request-scoped Android DoH connections prevent stop latency and goroutine
  accumulation across in-process restarts
- OEM background-protection guidance backed by public Android battery,
  background-restriction, standby-bucket and power-save signals. Xiaomi devices
  get explicit MIUI/HyperOS autostart and battery-policy review actions with
  safe standard Android fallbacks; unverifiable OEM switches are never reported
  as enabled

## Verified

- `testDebugUnitTest`, `lintDebug`, and `assembleDebug`
- `connectedDebugAndroidTest` on an Android 16 emulator
- File import through Android's system picker and active-profile persistence
- Start → Running → Stop → Stopped → Start lifecycle
- Mihomo controller on `127.0.0.1:9090`
- HTTP and SOCKS proxy listeners through emulator port forwarding
- Android TUN TCP/UDP through the gVisor stack; Chrome successfully loaded
  `example.com` and a Google search through the active subscription
- Complex AI commands on the Android 16 emulator:
  global low-latency switching, repeated switching, Netflix Japan availability
  refusal, `skk.moe` US routing, YouTube group routing, and rule de-duplication
- Actual `ip.skk.moe` Chrome traffic matched the generated
  `DOMAIN-SUFFIX,skk.moe` rule; the current subscription exit then refused the
  upstream connection, confirming routing correctness separately from provider
  availability
- Replaced the expired test subscription on 2026-07-28 and verified 15 healthy
  leaf nodes, live Hong Kong browsing, AI reassignment of `skk.moe` to a US
  node, a real US exit response, and active lowest-latency switching
- Verified profile-scoped AI rules on the Android 16 emulator: a unique rule was
  absent while the legacy profile was running, then restored after switching
  back to the current subscription; Mihomo validated and started under both
  profiles
- Alternated the two real profiles 20 consecutive times while VPN was running;
  every transaction reached the requested profile and returned to `Running`,
  with no stop timeout, duplicate core, or residual TUN
- Sent five rapid Activate taps; observed exactly one stop request, one profile
  activation, and one `Running → Stopping` transition
- Verified the post-switch Android VPN network was `VALIDATED`, with successful
  IP and Fake-IP/DNS connectivity probes
- Injected a one-shot native startup failure during a live profile switch;
  observed target activation and failure, complete failed-runtime teardown,
  automatic restoration of the prior snapshot, reconnection to `Running`, a
  persisted successful rollback record, and restored validated connectivity
- Verified rule enable, disable, policy rebinding, missing-policy exclusion, and
  deletion end to end; UI, scoped rule storage, materialized config, and live
  Mihomo reload stayed consistent, with validated IP and DNS connectivity
- Verified the node page against `/proxies`: manual Hong Kong selection,
  a 120ms per-node probe, and automatic selection of a measured 103ms Macau
  node all matched the controller, with metadata rows excluded and connectivity
  remaining valid
- Verified the home connection overview in normal, proxy-path rejection, and
  underlying Wi-Fi loss states. Health and exit requests explicitly traversed
  Mihomo's local mixed port; a temporary gstatic rejection produced an Internet
  failure while VPN/controller stayed healthy, then recovered after live rule
  removal with no test rule left behind
- Verified a real two-service LLM plan end to end: Netflix/Hong Kong and
  YouTube/United States produced two ordered rules and live reloads. The same
  Japanese request produced two parsed operations but safely stopped before
  mutation because the current subscription's Japanese nodes were unavailable
- Verified AI transaction behavior on the Android 16 emulator: a second-step
  preflight failure left no first-step rule; injected failures after rule reload
  and after a real Selector change restored both the rule store and original
  `千速云` selection; a normal two-rule batch committed successfully
- Verified local execution sources end to end for a no-space Chinese domain
  command, Netflix Hong Kong routing, and low-latency switching. All reported
  `source=local`; test rules were removed and the original automatic Selector
  was restored
- Verified diagnostic classification end to end for healthy traffic, an exact
  REJECT rule, real DNS failure, injected proxy-exit and target-only failures,
  and complete Wi-Fi/cellular loss; final runtime returned to a healthy HK exit
  with no test rules
- Verified auto recovery after two consecutive proxy-exit failures, original
  Selector restoration without runtime shutdown when candidates were exhausted,
  and suppression for an explicit probe-target REJECT rule. The final runtime
  returned to `千速云=自动选择`, 0 AI rules, and a real HTTP 204 through Mihomo
- Verified a real scheduled subscription refresh while the VPN stayed on the
  same process and foreground service, next-start adoption of the refreshed
  config hash, persisted history/diff UI, and byte-identical preservation of
  the prior generated config after an injected invalid-YAML refresh
- Verified real provider quota headers and UI values, migration from the legacy
  plaintext API-key preference to Keystore ciphertext, a redacted exported log
  bundle, a clean repository secret scan, and healthy proxied HTTP 204 traffic
- Ran the complete Android device suite on the Android 16 arm64 emulator:
  all 18 instrumentation tests passed with no skips (14 lifecycle fault cases,
  one application-context case, and three Compose UI cases for startup,
  background guidance, and the realtime log viewer). The
  matrix includes the packaged shutdown-hang hook, post-timeout late-start
  cleanup, asynchronous startup-stage mirroring, and a late connectivity
  callback racing an active shutdown
- Passed `go test ./...`, Debug unit tests, Debug/Release builds, and `lintDebug`
  after the lifecycle fixes; the restored final runtime is `Running`, controller
  and Internet checks are healthy, and a real proxied gstatic request returns 204
- Extended AI-rule regression with direct/reject, regional domain routing,
  low-latency switching, four multi-service LLM rules, Disney/Telegram geosite
  routing, duplicate/upsert behavior, and unavailable-region atomic refusal;
  every accepted rule was verified against Mihomo's live match log and real traffic
- Verified startup progress on the Android 16 emulator at both boundaries:
  a release-controlled native gate held the service at `STARTING_RUNTIME` until
  released, and a Compose instrumentation test confirmed the visible milestone,
  percentage, and progress bar before automatic cleanup
- Removed all 11 temporary AI rules after the regression, restored the original
  selector, and reverified `Running`, controller/Internet health, 0 AI rules,
  encrypted API-key persistence, and proxied HTTP 204
- Installed the R8-optimized Release APK on the Android 16 arm64 emulator,
  imported and activated the real subscription (33 proxies, 3 groups, 514
  rules), reached `Running`, queried Mihomo 1.10.0, and received HTTP 204
  through the mixed port
- Verified the optimized universal APK at approximately 249 MiB and the Android
  App Bundle at approximately 118 MiB; the release manifest disables backup
- Cleared emulator app data and verified the complete first-use UI path: the
  home action opened configuration import, a real subscription auto-activated,
  the action changed to Start and then Disconnect as VPN state advanced, key
  storage remained encrypted, and proxied traffic returned HTTP 204
- Verified the API-key editor and runtime log expand/collapse controls, prompt
  retention across VPN startup, node-action gating, and the new pure state
  mapping tests for every engine state and AI prerequisite
- Ran one-tap latency probing against the real subscription: 31 unique nodes
  were deduplicated across groups, progress updated during execution, and the
  final 10-success/21-failure result was reflected in per-node rows without
  changing the selected policy
- Killed the UI process while connected and verified the Veercore PID,
  controller and real proxied HTTPS remained healthy; relaunched UI synchronized
  to Running
- Killed the Veercore process while the UI remained alive and verified a new
  PID recovered controller and real proxy traffic in about 7 seconds; explicit
  stop remained stopped and fast reconnect recovered in about 1.55 seconds
- Verified cross-process rule hot reload from the main-process AI receiver by
  observing the Go reload in the Veercore PID and the Dashboard rule count
  update within 2 seconds
- Recorded schema-2 per-process performance baselines: background UI/core PSS
  90,587/125,756 KB and CPU 0.000/0.332%; optimized foreground aggregate CPU
  1.164%
- Re-ran the final source gate after the cross-process ordering fixes:
  `testDebugUnitTest`, Debug APK, Android-test APK, Release APK, Release AAB,
  and `lintDebug` all passed. The restored emulator has distinct UI/core PIDs,
  reports Running/controller/Internet healthy in the UI, serves Mihomo 1.10.0,
  and returns HTTP 204 from both Cloudflare and gstatic through the mixed port
- Generated all four ABI outputs from one Release variant: arm64-v8a 89 MB,
  armeabi-v7a 84 MB, x86_64 94 MB, and Universal 249 MB, plus a 118 MB AAB.
  Package/version metadata and native-library membership matched every target,
  and all five SHA-256 entries reverified
- Installed locally signed copies of the arm64-v8a and Universal Release APKs
  on the arm64 Android 16 emulator. Both reached Running with distinct UI/core
  PIDs, Mihomo 1.10.0, and HTTP 204 from Cloudflare and gstatic. The available
  AVD is arm64-only, so x86_64 and armeabi-v7a runtime acceptance remains open
- Exercised the protected signing path with an ephemeral test identity outside
  the repository: four APKs shared one verified certificate, the AAB signature
  verified, and `VEER_REQUIRE_SIGNED=1` accepted the signed set. This validates
  the mechanism, not a production signing identity
- Verified SI-09 on Android 16: VPN LinkProperties contained `fc00::/7 throw`
  and `fe80::/10 throw`, the assigned TUN `/126` remained connected, the VPN
  reached Running, and Mihomo controller plus Cloudflare/gstatic HTTP 204
  stayed healthy. Host tests also proved the API 29–32 nine-route IPv6
  complement has exact coverage and no overlaps
- Verified SI-10 on Android 16: LinkProperties additionally contained
  `169.254.0.0/16 throw` and `224.0.0.0/4 throw`; a host test proved the
  40-route API 29–32 IPv4 complement has exact coverage and no overlaps, while
  CGNAT and public destinations remain tunneled
- Verified per-app routing on Android 16 at the framework UID boundary:
  selected-only Chrome produced a VPN range containing Chrome UID 10162 but
  not Veer UID 10242; bypass-selected excluded both UIDs. Both live changes
  reused the same Veercore PID and drained the prior runtime in 10–19 ms.
  Restored all-apps mode and reverified Running, controller and actual Internet
  health. Full unit/lint/Release gates and all 18 device tests passed
- Ran the complete 14-case lifecycle/fault suite on a physical Xiaomi Mi 10S
  with HyperOS 1.0, Android 13/API 33 and arm64-v8a: all tests passed in
  53.639 seconds. A focused stop-then-immediate-start case passed in about
  4.7 seconds, and repeated restart batches showed no accumulating goroutines
- On the same physical device, verified independent UI/core processes,
  controller HTTP 200, real Cloudflare/gstatic HTTP 204 traffic, Wi-Fi recovery,
  Doze/background survival after the required OEM allowances, and all-apps,
  selected-only and bypass-selected VPN UID policies
- Rebuilt both production and fault-injection gomobile AARs, then passed
  `go test ./...`, `testDebugUnitTest`, `lintDebug`, `assembleDebug`, and the
  R8-optimized `assembleRelease` after the physical-device fixes
- Verified the new background advisor on the HyperOS device: it classified the
  OEM as Xiaomi, observed the existing Android battery exemption and no explicit
  background restriction, retained the honest manual OEM-review warning, and
  successfully resolved the autostart, battery-policy and app-details settings
  entries. Locked-screen Compose validation is intentionally skipped before
  rule setup and remains an unlocked-device UI gate
- Completed the dedicated realtime log viewer with bounded UI/Core snapshots,
  source/level/search filters, lifecycle-aware pause and refresh, copy, and
  Storage Access Framework export. Copy/export apply a second redaction pass
  even though both producers already redact before storage and IPC
- Fixed an Android 16 service-generation race where a newer Start could arrive
  after the prior generation had fully drained but before Service destruction;
  a safe drained instance now cancels finalization and immediately owns the new
  generation
- Closed two native late-registration leaks without extending VPN teardown:
  closed gRPC-over-HTTP clients can no longer recreate a transport, and a DoH
  connection racing resolver close is rejected atomically
- Rebuilt full-ABI Debug/Release AARs and passed the final source gate:
  targeted Go tests, clean Debug unit tests, Lint, Debug, AndroidTest, and
  R8-optimized Release builds. The Android 16 arm64 suite passed 18/18
- Re-ran the physical HyperOS lifecycle matrix at 14/14, then restored the
  production VPN. The current runtime reported Running, controller HTTP 200,
  proxied HTTP 204, and a redacted 224-entry log snapshot (24 UI, 200 Core)
- Completed per-profile custom DNS settings with normal DNS, DoH, DoT,
  TCP/UDP/QUIC, fake-ip/redir-host, IPv6 response control, bootstrap validation,
  and entry points from both Home and each profile card
- Split generated profile storage into raw input, safe base config, and effective
  runtime config. Subscription refresh replaces the base then reapplies the
  profile-scoped DNS policy; INHERIT restores the newest base byte-for-byte
- Verified a live DoH apply and safe reconnect on Android 16, followed by an
  exact restore to provider DNS. Both paths returned controller/DNS HTTP 200
  and proxied gstatic HTTP 204
- Injected a one-shot native startup failure during DNS save. The UI reported
  rollback, persisted YAML/policy/hash returned to the previous state, the old
  config restarted to Running, and controller/DNS/proxy checks returned
  200/200/204
- The Android 16 arm64 suite now passes 19/19. The physical HyperOS lifecycle
  matrix remains 14/14 after installation, and its restored runtime returned
  Running with controller/DNS/proxy results 200/200/204
- Passed the clean final source gate with Debug unit tests, Lint, Debug,
  AndroidTest, and R8 Release builds. Universal Debug D8 merging required a
  temporary 6 GiB Gradle heap; no project default was changed
- Hardened the AI control path with an explicit non-mutating clarification
  action, truthful rejection of unsupported DNS changes, committed-result-only
  feedback, and plan-shape validation at the execution boundary
- Extended the conservative local parser to cover multi-service/multi-region
  commands, service DIRECT/REJECT rules, English shorthand, and usable nodes
  whose health has not yet been measured. Local commands now remain available
  without an API key; only unresolved language requires DeepSeek
- Verified on the physical HyperOS device that a local two-step command loaded
  Netflix to a Japan node and YouTube to a US node. A known-bad Hong Kong node
  was rejected without fallback. Reassigning `ip.skk.moe` from Japan to the US
  changed real HTTPS edge evidence from NRT to LAX and matched the live rule
  table and UI route summary
- Removed all three temporary AI rules through the app and reverified Running,
  controller and Internet health with 0 active AI rules
- Fixed stale-session behavior after AI rule updates by closing only established
  connections affected by the committed rule. Repeating an unchanged command now
  also refreshes matching sessions, which was verified against a live ChatGPT TLS
  connection without draining unrelated traffic
- Diagnosed the physical-device ChatGPT failure beyond routing: provider UDP DNS
  returned unrelated Facebook/Twitter addresses for OpenAI hosts, producing Chromium
  `net_error -100` certificate-name failures. Inherited plaintext-only DNS is now
  hardened to Cloudflare DoH and its pollution-prone fallback selection is removed;
  explicit custom DNS remains user-controlled
- Applied the hardened DNS to the active HyperOS profile. OpenAI and gstatic answers
  returned to their real Cloudflare/Google ranges, and a cold ChatGPT App launch loaded
  Chat, Projects, Pinned and Recents with no TLS or certificate error. The final gate
  passed 166 unit tests, Debug Lint and Debug APK assembly
- Fixed a physical-device test hang: StartupProgressUiInstrumentedTest now shares the
  same focus-availability rule as the other Compose host tests and has a hard 10-second
  timeout. The Xiaomi run no longer stalls after 18/19 cases
- Added `tools/run_device_tests_preserving_app.sh` for shared phones. It updates the
  target with `adb install -r`, invokes the runner directly, and removes only the test
  package, avoiding AGP's destructive post-connected-task target uninstall
- The data-preserving run completed all 19 entries in 43.983 seconds: all 14 lifecycle
  and fault-injection cases plus the context test passed, while four Compose host tests
  skipped immediately under the documented Xiaomi policy. Profile, encrypted DNS and
  AI rule files remained installed and the production VPN was restored healthy
- Fixed the remaining ChatGPT routing failure for apps that resolve hosts internally.
  Their real-IP TUN connections previously had no hostname and fell through to the
  subscription's Singapore MATCH route despite a higher-priority OpenAI GEOSITE rule
- New and already-saved profiles now receive HTTP, TLS and QUIC hostname sniffing during
  generation and runtime materialization. A cold ChatGPT launch showed OpenAI hosts
  matching the US04 rule, and the device OpenAI HTTPS probe changed from TLS timeout to
  the expected unauthenticated HTTP 401 response
- The updated source gate passed 167 unit tests, Debug Lint, both Debug APK builds and
  the full data-preserving 19-entry physical-device instrumentation run
- Added a bounded, profile-scoped AI operation history containing the original prompt,
  LOCAL/LLM/SYSTEM source, committed result, actual rules and reversible before/after
  snapshots. It never stores API credentials and Android backup remains disabled
- Replay re-enters the current resolver and validation pipeline. Undo uses optimistic
  state checks and compensating rollback, so an older entry cannot overwrite later
  rule or selector changes. A physical DIRECT-to-REJECT chain verified conflict refusal
  followed by two exact reverse-order restores
- Added review-before-run quick templates and a recent-history panel with replay and
  undo actions. The final gate passed 171 unit tests, Debug Lint, Debug/AndroidTest APKs,
  R8 Release and the data-preserving 19-entry HyperOS run
- Closed the remaining Round 1 emulator gate on an Android 16.1 arm64 AVD using the
  ABI-specific Debug APK. The live dashboard chart, connection details, node filter
  controls, quick templates and empty-history state were all visually verified while
  VPN, controller and Internet status remained healthy
- Added a unified Settings activity for encrypted AI credentials, profile-aware DNS,
  per-app routing, background protection, appearance, and build information. Home now
  keeps only the six high-frequency runtime/navigation actions
- Added persistent system/light/dark appearance backed by a process-wide StateFlow.
  Every existing activity observes the same value, and Main refreshes API-key readiness
  after returning from Settings
- The Settings gate passed 175 unit tests, Debug Lint, Debug/AndroidTest APKs, R8
  Release, a focused Compose test, and the full 20-entry Android 16.1 instrumentation
  runner. HyperOS was updated without data loss and restored to Running; its in-app
  diagnostic reported physical network, TUN, controller, DNS, routing, node, proxy exit,
  and target-site health all passing
- Started the Round 3 i18n migration with English defaults and complete Chinese
  overrides for 150 resource keys. Home, startup progress, AI templates/history,
  Settings, background protection, and all Activity labels now resolve at composition
  time; user data, rules, node names, and diagnostic evidence remain verbatim
- Android 16.1 switched the running app between en-US and zh-CN and rendered both Home
  and Settings correctly without reinstalling. The 21-entry instrumentation runner,
  175 unit tests, Lint, Debug/AndroidTest packaging, and R8 Release passed. HyperOS also
  passed the locale resource test after a data-preserving update and returned to Running
- Completed the Profile i18n slice across the list, detail screens and ViewModels. The
  shared `UiText` model delays resource resolution and supports nested localized failure
  stages; both locale sets now contain 230 matching keys and the Profile package has no
  hard-coded Chinese UI text
- Android 16.1 rendered the Profile import and empty states in both English and Chinese;
  all 22 instrumentation entries and 175 unit tests passed. HyperOS passed the focused
  two-test resource suite after a data-preserving update and returned to Running
- Completed DNS i18n across its Activity, ViewModel and validator. Validation now returns
  typed problems instead of Chinese presentation strings, while the UI localizes all 13
  validation categories and delayed save/reconnect/rollback states. Both locale sets now
  contain 299 matching keys
- Android 16.1 passed the full 23-entry runner and exercised the custom DNS flow in both
  English and Chinese. HyperOS passed the three-test locale suite without changing its
  real DNS policy, then returned to Running
- Completed Rules i18n across the Activity, ViewModel and presentation model. Nested
  `UiText` values localize match descriptions and explicit traffic exits while preserving
  raw Mihomo rules, domains, node names and policy values; both locale sets now contain
  347 matching keys
- Android 16.1 passed the full 25-entry runner and exercised a Netflix-to-HK rule card
  and exit picker in both languages. HyperOS passed the four-test locale suite without
  mutating real AI rules, then returned to Running
- Completed Nodes i18n across the Activity, ViewModel and delay presentation. Controls,
  filters, probe progress and operation results localize while node/group names, proxy
  types, region codes and delay values remain unchanged; both locale sets now contain
  382 matching keys
- Android 16.1 passed the full 27-entry runner and exercised delay sorting and unavailable
  filtering in both languages. HyperOS passed the five-test locale suite without switching
  real nodes or launching a batch probe, then returned to Running

## Current limitations / next work

1. Provision the real production release key in protected developer/CI secret
   storage. The integration is complete, but default local output remains
   explicitly unsigned and must not be distributed.
2. Run the x86_64 APK on an x86_64 emulator and the armeabi-v7a APK on a real
   32-bit ARM environment before the first public release.
3. HyperOS physical-device core coverage is complete on one Android 13 device.
   Repeat the matrix on a Pixel and newer MIUI/HyperOS hardware, then cover
   ColorOS/OriginOS, a real Wi-Fi/cellular round trip, and unlocked first-run/
   background-guidance UI.
4. Add an Android Quick Settings Tile for explicit connect/disconnect with
   permission, active-profile, transitional-state, and error guidance.
5. Continue the i18n second phase with Per-App, then Logs and Connections;
   Home/AI/Settings/Profile/DNS/Rules/Nodes are complete.
6. Replace the interim provider command surface with typed Binder/AIDL if future
   command volume or acknowledgement requirements outgrow the current bounded IPC.

Before changing runtime ownership, JNI, VPN lifecycle, teardown, timeouts, or
watchdog behavior, read all governance documents in this directory—especially
`runtime_invariants.md` and `native_runtime_contract.md`.
