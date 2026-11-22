# App routing (Phase 1, test version, 2026-11-20)

Route chosen apps and command-line tools through an exit, always direct, or blocked, with Mihomo's
process rules. No system extension, no TUN requirement, one Mihomo. Phase 2 (a native per-app
transparent proxy) is research only: [PER_APP_PROXY_FEASIBILITY.md](PER_APP_PROXY_FEASIBILITY.md).

Status: uncommitted working tree on `main`; checked in an isolated build
(`.build/probe/approuting/build.sh`, bundle `com.yamax.veer.approuting`). `dist/Veer.app` untouched.

## 1. Mihomo audit (v1.19.29, commit `e26714a`, the tag `scripts/build-mihomo.sh` pins)

Read from the upstream source of that commit.

| Question | Answer |
|---|---|
| How a process is found on macOS | `component/process/process_darwin.go`: read the whole `net.inet.tcp.pcblist_n` (or `udp`) with `sysctl`, find the socket whose local port is the connection's source port, take `so_last_pid`, then `proc_pidpath`. `Process` is the path's last component, `ProcessPath` the full path. |
| What the path looks like | The kernel's real path: `/private/tmp/...`, not `/tmp/...`. Foundation's `resolvingSymlinksInPath` drops `/private`, so Veer uses `realpath(3)`. |
| `strict` | Lazy: the lookup runs the first time a PROCESS rule is evaluated for a connection (`RuleMatchHelper.FindProcess`). A connection decided by an earlier rule is never looked up. |
| `always` | Every connection is looked up before matching. |
| Global / Direct mode | `tunnel.resolveMetadata` picks `GLOBAL` / `DIRECT` without matching, and no lookup runs. App rules do nothing there. |
| Matching | `PROCESS-NAME`, `PROCESS-PATH`: case-insensitive equality. `*-WILDCARD`: both sides lowercased, `*` crosses `/`, `?` is one byte. `*-REGEX`: regexp2, ignore case. |
| Syntax hazards | A rule is split at commas (except `*-REGEX`, logic and `SUB-RULE`); a logic rule is split at parentheses; items are trimmed of spaces. |
| What `/connections` reports | `metadata.process`, `metadata.processPath`, `rule` (`ProcessPathWildcard`, `AND`, ...) and `rulePayload` (for `AND`: `((ProcessPathWildcard,X) && (DomainSuffix,y))`). |
| Unknown policy | `parseRules` fails the whole config: a rule never falls back to DIRECT silently. |
| Android-only options | `include-package` / `exclude-package` are not used. |

Veer's existing behaviour: `RuntimeSettings.processMatching` (on by default) writes
`find-process-mode: always`, for the Connections page's process column. Kept; see §5 for the cost.

## 2. Architecture

```text
VeerCore   AppRouting.swift       AppIdentity, AppRule, AppRuleBuilder (rules), AppAttribution, SharedProcesses
           AppRoutingAgent.swift  Agent tools: AppRouteRequest, AppLookupResult, AppReferences, AppRoutingProposal
VeerProxy  AppDiscovery.swift     bundle/helper/tool discovery, AppCatalogStore (cache/apps.json)
           AppRuleBlock.swift     writes the block at the top of `rules`
           RoutingLayer           `appRules: [AppRule]` per profile ("my routing"), applied in `apply(to:)`
VeerApp    ProxyStoreAppRouting   catalog, validated apply + rollback, reload, reconnect, undo, Agent lookup
           AppRoutingView         Proxy page view (third option of the Grid/Map switch)
           ConnectionsView/Table  app filter, context menu, app rule in the route map
           Agent/AgentAppRouting  proposal card, check, apply by execution mode, undo
```

- **Identity.** `AppIdentity.id` is the bundle ID (else the path): Veer's handle, never written into a
  rule. Rules match the bundle's real path.
- **Discovery.** `/Applications`, `/System/Applications`, `~/Applications` and one level of subfolders;
  running apps from `NSWorkspace.runningApplications`; any `.app` or executable picked by hand.
  Helpers found in `Contents/MacOS`, `Helpers`, `XPCServices`, `Library/LoginItems`,
  `Library/LaunchServices`, `Frameworks/*.app` (Electron) and `Frameworks/*.framework/Versions/*/Helpers|XPCServices`
  (Chromium), at most 64. Flavor: Electron, Chromium, WebKit (Safari), system, native, command line.
  Cached in `cache/apps.json`; a bundle is read again only when its `Info.plist` changed. An app that
  moved (same bundle ID, old path gone) has its rule follow it.
- **Attribution.** A connection belongs to an app only when its `processPath` is inside the app's
  bundle (or equals the tool's path). Never by name; a shared system process (WebKit networking,
  `nsurlsessiond`, ...) or a missing path is shown as unidentified.

## 3. Rule generation

For each enabled rule, in the user's order:

1. Its domain exceptions: `AND,((<app matcher>),(DOMAIN-SUFFIX|DOMAIN|DOMAIN-KEYWORD,<value>)),<target>`.
2. Its own exit: `PROCESS-PATH-WILDCARD,<bundle>/*,<target>` for an app (covers every helper in the
   bundle), `PROCESS-PATH,<path>,<target>` for a tool.

Then:

- **Escaping.** A path holding `,` `(` `)` `*` `?` `'`, or a space at either end, becomes a wildcard
  with `?` in those places. A name that differs between NFC and NFD gets one rule per form (compared
  by bytes: Swift's `==` treats them as one string).
- **Local network guard.** When any rule sends an app somewhere other than DIRECT, the block starts
  with `IP-CIDR(6),<range>,DIRECT,no-resolve` for loopback and the ranges Veer already keeps off TUN
  (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, `::1/128`, `fd7a:115c:a1e0::/48`, `fe80::/10`).
  A blocked app still reaches the local network.
- **Targets.** Follow profile (no rule of its own), DIRECT, REJECT ("block network access"), any group
  or node. A target that no longer exists (subscription changed, node unchecked) is left out and
  reported as "Exit X no longer exists; this traffic follows the profile's rules": never DIRECT.
- **Conflicts.** A later rule for an app an earlier one already takes whole is reported as shadowed
  and not written. The profile's own PROCESS / UID / logic-with-PROCESS rules are listed as overruled.
- **Priority in the config the core runs.** Veer's QUIC block, the hot rule sets, the app block, "my
  routing" edits, the profile's rules. While app rules exist, a new domain route from the Agent
  reloads instead of using a hot rule set, so it cannot sit above the app rules for one run and below
  them after a restart.
- **Apply.** The new layer is applied in memory, the runtime config built and checked with the
  bundled `mihomo -t`; only then saved. On the running core: `PUT /configs` without closing
  connections (open ones keep their route; "Reconnect" closes only that app's). If the core refuses
  the reload, the previous rules are saved back and reloaded, and the error is shown. Undo and redo in
  the Edit menu.
- **Mode.** The view says when app rules are not in effect: core stopped, Global or Direct mode (with
  "Switch to Rule Mode"), or "Match by process" off (with "Turn On").

## 4. UI, Connections, Agent

- **App Routing view** (Proxy page, third option of the top-row switch, also in View menu): profile
  name, state line, rules in priority order (drag, ⌥↑/⌥↓, context menu), each with icon, name, status
  ("In effect · 3 connections identified", "Disabled", "Exit … no longer exists", "Rule 2 already covers
  this app", "Not in effect"), exit menu and switch. Detail of the selected rule below: path and bundle
  ID, helpers covered, WebKit/system/translocated/moved warnings, domain exceptions, the rules written,
  Reconnect. Add App sheet: search, All/Running/Installed, icons, "Choose Another App or Command-Line
  Tool…". Rows go to two lines beside the Agent panel; when the window is too short the detail opens in
  a sheet ("Details…").
- **Connections:** "All Apps" filter (by path; "Unidentified Apps" for the rest); context menu
  "Choose an Exit for X…", "Always Send X Direct", "Block Network Access for X…" (confirmed), "Show App
  Rule for X", "Ask Agent: Where Does X Go?"; unidentified rows say why instead. The route map shows
  "App routing: X → exit" (or the domain exception, or the local guard) for a connection that hit one.
- **Agent:** two reply kinds in the strict JSON protocol. `{"apps":{"query":…}}` (list, inspect and list
  rules; read-only; at most 3 per turn) answers with references `app-N`, names, bundle IDs, running state
  and flavor notes, never paths. `{"appRoutes":{"changes":[…]}}` names those references and exit labels
  (or DIRECT, REJECT, PROFILE) and becomes a card: each app now → after, a Mihomo check, Apply/Discard,
  then Undo and "Reconnect These Apps". Execution modes: Manual and Plan never apply; Auto applies only
  routes with a passed check (never a block or a removal); Accept Edits needs a passed check; Full applies
  unless the check failed; a turn with attachments always waits. Process paths in configs sent to the AI
  have the home folder replaced by `~`.

## 5. Results (this session)

**Unit and integration tests** (`verify.sh`, all targets, bundled Mihomo): 575 pass. New: `AppRoutingTests`
(12), `AppRoutingAgentTests` (6), `AppRoutingLayerTests` (7) and `AppRoutingMihomoTests` (every generated
form, including commas, parentheses, apostrophes, NFC/NFD and logic rules, accepted by `mihomo -t`).

**Process identification** (`.build/probe/approuting/harness.py`, a test Mihomo bound to 127.0.0.1, every
app target ending in REJECT so nothing dials out; one compiled client copied to three paths):

| Client | Expected | `always` | `strict` |
|---|---|---|---|
| tool at its exact path | `ProcessPath` | ✔ | ✔ |
| helper in `Fake App (Beta), v2.app/Contents/Frameworks/… Helper (Renderer).app` | `ProcessPathWildcard` | ✔ | ✔ |
| unrouted tool to `blocked.test` (app + domain) | `AND` | ✔ | ✔ |
| unrouted tool elsewhere | `Match` | ✔ | ✔ |
| tool to a loopback address | local guard `IPCIDR` | ✔ | ✔ (not looked up) |

10 of 10. A copied `/usr/bin/curl` would not run from a new path (code signing) and framework Python
re-execs into another binary, so neither is a reliable known executable for such a test.

**Cost** (same harness; macOS 27.3, Apple silicon; medians of 300; one connection per request):

| Core | New TCP connection, local guard decides | New TCP connection, every rule read | 256 MB download | UDP round trip (SOCKS5) | Reload (`PUT /configs`) | RSS after run |
|---|---|---|---|---|---|---|
| `off`, no app rules | 0.24 ms | 0.09 ms | 3.7 GB/s | 0.05 ms | 1.1–1.3 ms | 33.7 MB |
| `always`, no app rules | 3.9 ms | 4.0 ms | 2.9 GB/s | 0.05 ms | 1.1–1.4 ms | 46.4 MB |
| `always`, 500 app rules | 4.6 ms | 4.3 ms | 3.0 GB/s | 0.05 ms | 1.2–1.3 ms | 44.5 MB |
| `strict`, 500 app rules | 0.23 ms | 4.1 ms | 3.1 GB/s | 0.05 ms | 1.2–1.4 ms | 45.5 MB |

- A process lookup in this Mihomo costs about **3.7 ms per new connection** (latency and CPU: ~4 ms of
  core CPU each). The kernel part is small: a C replica of the same `sysctl` + `proc_pidpath` took 5–12
  µs with ~170 TCP sockets and ~30 µs with ~2,500. Where the rest goes inside Mihomo's Go path was not
  determined (NOT VERIFIED).
- 500 app rules add 0.3–0.6 ms per new connection; throughput, UDP and reload time do not change
  measurably. Established connections pay nothing.
- With app rules at the top, `strict` looks up every connection the local guard does not decide, so it
  saves the lookup only for local traffic. Veer keeps `always` (the shipped default, needed for the
  Connections page's process column). Whether to default to `strict` and lose that column is a product
  decision for the user.
- App list: cached list at once; a full scan of this Mac's folders runs off the main thread;
  its time is recorded in `ProxyStore.apps.scanDuration` but was not read out this session (NOT VERIFIED).

**Screens** (`.build/probe/approuting/snaps3`, `snaps6`; zh-Hans and en; light and dark; inactive windows;
default, 860 × 560, 1440 × 900, beside the Agent panel, 280 pt page): App Routing populated, empty,
Global mode, stopped, detail; Add App sheet; Connections with an app rule hit; the Agent proposal card.

## 6. Not verified

- Live traffic in the real app: no Veer core was started (the user's FlClash owns the system proxy).
  Identification was proven with the test core above, not through the app.
- Keyboard (⌥↑/⌥↓, Delete, focus), VoiceOver, an active window's look, Reduce Motion/Transparency,
  the Domain Exception and Choose Exit sheets (no scene), the "Details…" sheet, undo and redo in the
  Edit menu, a real AI turn, macOS 14 VM.
- Safari/WebKit and system apps: their shared processes are excluded by design; how much of a given
  app's traffic that leaves uncontrolled was not measured.
- App Translocation and apps on other volumes; NFC/NFD names on a real file system.
- Older Veer versions reading a thread saved with an app-routing turn (a new `Turn.Outcome` case) or a
  layer with `appRules`: an older Veer reads the layer without the field and drops the app rules the next time it saves that layer; the thread would fail to decode.
