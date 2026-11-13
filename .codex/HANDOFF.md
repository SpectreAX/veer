# Veer macOS handoff

## Android repository archival migration (2026-11-13, Codex)

User authorized moving the GitHub repository SpectreAX/veer-android into Veer's android/deprecated/, updating the root README and archiving the original. Import source is its default main branch at 7f1af61ded6785d366629227047832a6327268e2 (35 commits, 1,659 tracked files), preserved with a non-squashed Git subtree merge. Git LFS payloads must be copied to Veer's LFS storage before the original is archived; a Git-tree-only copy is insufficient. Other source branches stay accessible in the original read-only repository.

The migration is isolated on codex/archive-android from Veer origin/main@9f235f2. Do not include the unrelated dirty macOS changes in the primary checkout or uncommitted Android work on agent/ui-refactor-sync. The original local Android checkout is preserved. Root .gitignore now permits only android/deprecated/ under android/, and root AGENTS plus macos/docs/WORKFLOW.md describe the archive rather than a separate active Android repository. App source, builds and releases are outside this migration.

Acceptance requires exact source/imported tree identity, source commit ancestry, all historical LFS payloads present on destination, verified README links, merge into GitHub Veer main, and archived=true on the original repository. The migration does not establish Android or macOS build/runtime verification.

## iOS Simulator prototype — Simulator acceptance PASS (2026-11-12)

- Owner approved the Simulator-only brief `.airbuild/artifacts/ios-prototype-brief-v0.3.md`.
  Bundle `com.yamax.veer.ios-prototype`, iOS 26+, portrait iPhone, zh-Hans/en, three tabs.
  `ios/` shares VeerCore/VeerProxy and the Agent store; no NetworkExtension, device-wide proxy,
  TUN, accounts, telemetry, device distribution, TestFlight or App Store work. No commit or push.
- Prototype-only licence exception: pinned Mihomo v1.19.29 is self-built as a C archive and linked
  into the app. Mac's separate-process rule is unchanged. Keep `ProxyCore` abstraction; any
  distribution requires a replacement core or a new licence decision.
- First embedded-core/store builds and sample import/start/stop ran successfully in Simulator.
  Three-tab UI + Import, Settings, Connections, group detail, Conversations, payload and proposal
  views are now implemented; **final integrated build/Simulator verification still pending**.
  Design: `/run/airbuild/team/state/team/design/veer-ios/design.md` and its PNGs; copy merged only
  into `ios/Localization/*.ios.strings` via `ios/scripts/sync-strings.py` (Mac copy untouched).
- A read-only store review found start-stop-start/profile-activation/reload ordering races.
  Active fixes are isolated to iOS `ProxyStore`, `CoreLifecycle`, hot-update helper and race tests.
  Do not use earlier green builds as proof these changes pass. First parent integrated snapshot
  `/tmp/veer-integrated-build.log` failed because it captured the in-progress missing `enqueueHot`.
- Fixture construction now separates files/defaults/memory-only secrets before either store.
  Uses no real lookup/search/verifier. Shared AgentStore's settings model-list client is injectable
  with an unchanged real-client default for Mac; fixture passes recorded transport there too.
  Unit tests may inject UUID temp paths/defaults and a mock `ProxyCore` into `AppModel`.
- Fresh Mac regression before the latest model-client injection passed: Build
  `852cc454-99e5-471c-bfc6-5bf12df12fff`, `.airbuild/artifacts/ios-mac-regression.log`.
  Pass/skip name sets match imported baseline exactly (421 passed/17 skipped/0 failed; 438 discovered).
  Final regression after the small shared edit is running separately, not yet claimed passed.
- Superseded: final Mac regression after the AgentStore edit PASS (Build 4df169a6,
  `.airbuild/artifacts/ios-final-mac-regression-report.json`); iOS unit tests PASS
  (`.airbuild/artifacts/ios-unit-tests.log`).
- Fixes during Simulator acceptance: node-switch crash (MainActor-default `UIColor` dynamic
  providers resolved off-main → `@Sendable` + `nonisolated extension UIColor`, UI/Theme.swift);
  mode switch/reload (embed mode has no PUT/PATCH /configs → Go `VeerCoreSetMode`/`VeerCoreReload`);
  DEBUG language override bundle; "Zero KB/s"; Agent tab no longer auto-focuses keyboard; single
  toolbar glass on Test All; AX3 hero status row stacks and exit IP stays on one line.
- Final build `d89d26c5-7b68-459f-865f-855e5dac0492` on iphone-18-pro (iOS 27.2) PASS: sample
  import, auto start, exit IP, Rule/Global/Direct, node select persists, delay test, fixture
  proposal apply + undo, zh-Hans + en, light/dark, AX3. DEBUG launch env: VEER_UI_LANGUAGE,
  VEER_IMPORT_SAMPLE=1, VEER_AUTO_START=1, VEER_FIXTURE_AI=1.
- Known/open: config reload (apply/undo) clears Mihomo delay history (core behaviour, accepted by
  Ato); Camo's msg54 copy supplement pending; new en key "示例" = "Sample" awaits Camo.
  NOT VERIFIED: VoiceOver walk-through, real AI provider, real subscription. Parser preflight
  (size-limited, fail-closed geodata/provider fetch) not done.
- Design review 1 (Colo msg70) + Ato msg68 applied, build `2d662639-01b0-4655-a30b-357a5bd91940`,
  iOS tests 25/25 PASS: 0 KB/s formatter (KB minimum), localized region tag from countryCode,
  fixture turns hide the step row and understanding is plain, composer pills one row leading
  ("示例" short pill, web search hidden in fixture), wrapping placeholder overlay, group-detail
  header aligned (-16) with absolute Color.secondary, toolbar glyphs .primary, undo/redo note
  turns hidden on iPhone only. Also fixed: Import uses PasteButton (UIPasteboard read was refused
  after a declined prompt), import buttons never wrap, fixture Settings shows only the sample
  label, failure card shows the raw error once and hides 更新订阅 for non-subscription profiles,
  SecondaryCapsuleStyle dims when disabled. Awaiting Colo's confirmation of those choices.
- DEBUG quirk: the first launch after `simulator install` with VEER_UI_LANGUAGE can mix
  languages (String(localized:) follows the device language); launch a second time.

## AirBuild import baseline (2026-11-11)

- Imported `SpectreAX/veer` at `76acb0f1f6ea89916496dbac75a31460414117e2` into AirBuild project
  `4038787e-3c0f-42ca-a0e0-1b5cc91b45aa`. This is the existing native macOS app, not an iOS conversion.
- Added platform-local `.airbuild/airbuild.yaml` and `.airbuild/scripts/prepare-macos.sh`:
  keep SwiftPM and existing packaging/verification scripts, dynamically select the Xcode SDK,
  build the pinned Mihomo core, and collect `macos/dist/Veer.app`. Core cache key includes the
  source-build recipe hash and architecture. No app, test, lint, identity, version or feature edits.
- Final native `runbuild` PASS after cache-key hardening: run
  `00be2744-cf14-45ca-a29b-9b9a7325a88a`, Build `63fa32e9-dc58-4ff9-9c6f-612274e6001a`.
  Test artifact saved at `.airbuild/artifacts/Veer-macos-test.app.tar.gz`; execution evidence
  `.airbuild/artifacts/final-native-build.log`. First native `runbuild` also passed: run
  `e6ca54bf-2ff1-41d3-b109-f79a6d370134`, Build `fe4e3763-0072-48d1-8c1b-c5435c9c4e28`.
  macOS 27.2 / Xcode 27.2 / Swift 6.4.2 / arm64.
  Existing package script's deep strict signature verification passed; forced ad-hoc test signing,
  not notarized, TUN unavailable in this artifact. No release, tag or push.
- Independent unchanged `verify.sh` PASS via `runtest`: run
  `84667d59-d1f4-4d52-b123-89d501c85c38`, Build `6a86d347-e59d-4d67-8872-284f36983a70`.
  Formatting, strict lint, build and tests passed: 421 individual passes, 17 optional skips,
  0 failures (438 discovered, including skips). Real release-core integration tests ran.
  Evidence: `.airbuild/artifacts/independent-native-verify.log` and
  `.airbuild/artifacts/independent-native-verification.json`.
- Existing compiler warnings remain (String cString deprecation, unnecessary nonisolated(unsafe),
  a non-Sendable callback conversion). Baseline scope did not change their source.
- Isolated sample-data screenshot check PASS using `.codex/scripts/snapshots.sh`, run
  `183b4304-bcbe-4f28-8bf4-9d2e45991dcc`, Build `a0529944-d7d8-4679-b1c4-a8397ba6eecc`.
  Generated 36 main-window captures (9 scenes × zh/en × light/dark) and 8 inert native TUN
  alert mockups. Actually viewed 8 representative main-window captures: overview, proxies,
  smallest proxy layout, Agent proposal, connections, narrow panel and failed-start state.
  No blocking static-render defect found in those eight. Full 44-image review NOT VERIFIED;
  alert mockups do not establish functioning TUN. Evidence:
  `.airbuild/artifacts/mac-verification/screenshots/`.
  macOS apps have no Team iPhone Simulator preview. Normal app launch, real proxy/TUN,
  keyboard/VoiceOver, macOS 14, live provider credentials and notarization remain NOT VERIFIED.

## Scope

Shared progress summary: [`macos/docs/PLAN.md`](../macos/docs/PLAN.md), section
“边栏动画与启动错误”. Update that document and this handoff after meaningful progress,
as the user requested, so Claude can resume through its usual development-plan entrypoint.

2026-11-01: after workflow migration the user authorized finishing Claude's remaining development.
The feature and workflow are being recorded as separate local commits. Publishing, enabling the
system proxy, and TUN tests on the real Mac remain outside authorization.

## Current implementation · native panel split (2026-11-11, Codex)

The user superseded the overlay proposal and authorized direct restructuring with both page and panel visible. Current branch fix/macos-panel-live-resize includes inherited uncommitted work plus PanelSplitView, a SwiftUI HSplitView with NSSplitView.setPosition updating the real divider and SwiftUI hosting proposals each frame. Snapshot masking is removed. MainView preferences stay in the same SwiftUI tree. Tables/grids choose destination columns, Overview uses actual width. Hidden stable panels unmount their contents and relinquish first responder.

Full verification passes 441 tests, including a new intermediate SwiftUI-proposal regression. CUA isolated-sample checks cover three pages, reversal, configured AI composer focus on close and Agent-page round trips. The older 600-row stress fixture reused c0…c5; its performance and selection conclusions are invalid pending a unique-ID rerun. The 400 nodes use unique names. A direct-frame optimization reached fast callbacks but failed actual rendered/proposal checks and was reverted. The final setPosition route really resizes content, but heavy-list and first-transition costs remain unresolved; do not claim the issue's 16ms frame gate passed. No real app replacement, proxy/TUN change or release.

See the [implementation and evidence record](../macos/docs/reviews/2026-11-11-panel-restructure.md). Work remains uncommitted. Preserve inherited changes, the initial diff is archived in ignored .codex/local/panel-restructure/inherited.patch. The [earlier issue handoff](../macos/docs/reviews/2026-11-11-animation-handoff.md) is historical.

## Connections table: curtain clipping (2026-11-12, Claude, chosen by the user)

After the real split (issue #15, direction B) the Connections table still jumped as the motion started: three columns vanished at once on opening, and on closing all seven were squeezed back into the narrow table. The user chose: columns never move or hide; the page's trailing edge covers and uncovers the far ones; the rest scroll horizontally. Order is now host, process, traffic, speed, duration, rule, chain; `firstColumnOnlyAutoresizingStyle`, host minimum 150; the width-fitting code in `ConnectionsView` is gone (`hiddenColumns` stays as a parameter of `ConnectionsTable`, passed empty). Sample frames viewed both ways (1080×720, dark, zh). verify.sh passed. Requests still uses a SwiftUI Table with hidden columns. Real window, light, en, 860×560, VoiceOver, macOS 14 not run.

## Claude follow-up on the native split (2026-11-12)

Claude resumed after a usage pause without noticing Codex had restructured the same uncommitted branch, and edited on top of it. Net effect on Codex's work: `ProxiesView` grid gets `.id(columns.count)` + `.transition(.identity)` so tiles are replaced in place when the column count changes instead of each travelling across the others; `PanelResizeTests` covers `columnCount`. An Overview change that arranged rows for the destination width was made and reverted (it is the vertical-text Major Codex closed). Sample frames (1080×720, dark, zh) viewed for Connections, Proxies, Overview both ways: one layer, readable, continuous. Real core on copied data (own bundle id, port 17890, proxy runner stubbed, TUN off; taken before the Overview revert): 15–17 ms a frame on Connections and Overview, Proxies 14–19 ms opening and 30–49 ms for six frames closing; screenshots add main-thread cost. verify.sh passed, 447 tests. Committed and merged as one PR with Codex's work. Correction: `ConnectionsTable` (Codex's native table) is what the Connections page shows; the earlier note that no view used it was wrong.

Stress follow-up (2026-11-12, Claude): 10 groups × 65 unique nodes, main-thread gaps measured without screenshots (probe mode `VEER_PROBE_STRESS`). Before: Proxies had one 107–191 ms gap as each toggle started, then 3–8 gaps of 24–83 ms; Connections one gap of 59–67 ms; Overview 4–6 gaps of 25–77 ms. The first gap on Proxies was partly the `.id` grid rebuild, now `.animation(nil, value: columns.count)` on the same grid: first gap 73–90 ms (176 on the first toggle), the rest unchanged. A 9 s `sample` shows 428 ms inside `NSSplitView.setPosition` spread over AttributeGraph updates, layout and display-list rendering with no single hot spot; no cheap fix found. Smoothness with large lists is still not at 16 ms.

## Main branch verification (2026-11-11, Codex)

Local and remote `main` matched at `76acb0f`. Public 1.0.6 build 7 includes the sidebar and empty-group fixes. PRs #13 and #14 subsequently merged the Agent panel snapshot and blur changes. The local dist app still reports 1.0.6/7 but contains the later `PictureLeaving` symbol. Deep strict signature verification passed.

Full verification with bundled Mihomo passed on this checkout, 438 tests (15 UI, 111 Proxy, 294 Core, 18 App). Log: `.codex/local/main-76acb0f-progress-verify.log`. The earlier frame reviews below are historical. Latest panel motion in the user's window, full screen, multiple displays and macOS 14 remains unverified. This check did not launch or replace the app.

## Development history (2026-11-11, Claude)

- Panel motion, round 4 (user screenshot: two sets of table columns over each other mid-fade). The page's
  picture now holds 0.06 s (a Table settles on its columns over a few frames), then blurs as it fades over
  0.15 s (`PictureLeaving`), inside the panel's 0.22 s slide. Sample-data probe, dark, Connections and
  Proxies viewed. Real window NOT VERIFIED.

- Panel motion, round 3 (user: 1.0.6 still not smooth). `ColumnReveal` is gone. The panel is a ZStack
  overlay with a move transition (zIndex 1, or it drops behind while leaving); the page makes room inside
  the detail column (`TrailingInsetLayout`). `ProxyStore.agentPanelWillChange` (willSet) lets `MainView`
  take a picture of the page first (`PageSnapshotSource`: the window's own pixels via
  `CGWindowListCreateImage` looked up with dlsym; `cacheDisplay` drops SwiftUI layers); the page lays out
  once under it and the picture fades as the panel slides. Tried and dropped: animated padding (relayout
  every frame), a non-animatable Layout (scroll content snaps). Real-core probe on copied data: 11–16 ms
  frames during motion. Real window, full screen, second display, macOS 14 NOT VERIFIED.

- Released 1.0.6 (build 7): PR #11 merged as `eac6e21`, tag `macos-v1.0.6`, GitHub release v1.0.6 on
  SpectreAX/veer-releases. Checked: verify.sh with VEER_MIHOMO_BIN; SDK 27.2 / minos 14.0; strict codesign;
  DMG mounts with signed 1.0.6; live appcast serves 1.0.6; DMG 200 with the same length. NOT VERIFIED:
  Sparkle 1.0.5 → 1.0.6, hands-on checks, TUN hot routing, macOS 14 VM.

- Panel motion, round 2 (user: Proxies/Connections still jump): real-core probe on a copy of the user's data
  (own bundle id, port 17890, system proxy runner stubbed to throw, TUN off, no state.json; proxy off before
  and after). Per-frame relayout cost 30–70 ms. Now the panel slides over the page and the page changes width
  once (`ColumnReveal.reservesSpace`), rearranging in that step; a cross-fade of the overview was tried and dropped (ghosts, offset).
  Slide frames 11–18 ms. Probe scripts: scratchpad/probe/{prepare_real.py,run_real.sh}. Real window NOT VERIFIED.

- Agent panel open/close: `ColumnReveal` (VeerUI) steps the panel's width per frame with the same NSAnimation
  driver as `SidebarAnimator`, so the split view and the overview get real intermediate widths. Overview
  breakpoint crossings animate (`Motion.standard`), left card above (zIndex) so the right one passes under.
  Probe frames viewed for overview open/close, proxies, connections; panel snapshot scenes fine. verify.sh
  passed; `ColumnRevealTests` added. DESIGN_SPEC deviation row added. Real window NOT VERIFIED.

- Hot rule sets under TUN: helper protocol v3 adds `writeRuleSets` (payload checked by `HotRuleSetFiles`:
  names `veer-hot-<n>`, ≤512 files, ≤1 MB each, 0600 in the root home's `veer-hot/`). `HotRuleSetWriter`
  picks local or helper; helper v2 stays compatible (`compatibleVersions`) and falls back to reloads.
  `start()` split for lint (no baseline change); hot code moved to `ProxyStoreHotRuleSets.swift`.
  verify.sh with VEER_MIHOMO_BIN passed. TUN path itself NOT VERIFIED (needs the user to turn TUN on).

- After 1.0.5: SwiftUI's hidden Help-menu "Hide Sidebar ⌥⌘S" (native `toggleSidebar:`, bypassing
  `SidebarAnimator`) is removed by `StraySidebarItems` (disarmed synchronously on add/change, removed
  after). Guarded probe: Help menu holds only "Veer Help"; ⌥⌘S unhandled; ⌃⌘S still toggles. verify.sh
  passed; `StraySidebarItemsTests` added. Branch `fix/macos-help-menu-sidebar`. Real window NOT VERIFIED.

- Released 1.0.5 (build 6) on 2026-11-11: PR #4 merged as `0fb5108`, tag `macos-v1.0.5`, GitHub release
  v1.0.5 on SpectreAX/veer-releases with the DMG and appcast. Checked: verify.sh (with VEER_MIHOMO_BIN)
  passed; dist app SDK 27.2 / minos 14.0, codesign strict ok, DMG verifies and mounts with a signed 1.0.5;
  the live appcast serves 1.0.5 and the DMG downloads (HTTP 200, same length). NOT VERIFIED: Sparkle
  update from 1.0.4, RELEASE.md section 2 hands-on checks, macOS 14 VM. Not notarized.

Codex's 2026-11-10/11 continuation is finished and committed locally on `feat/macos-agent-attachments`.
Not pushed (PR #3 is already merged, so this needs a new PR). See PLAN's “续修边栏与失败恢复”.

- Kept Codex's native divider animator (`SidebarAnimator`), detail viewport and failure recovery.
- Menu command now uses `@FocusedValue(\.sidebar)` from `MainView`; the window-notification
  availability flag was removed. The "always disabled" finding was a probe artifact: the probe never
  sent `menuNeedsUpdate`. With it, the item is enabled, its title follows the state, and ⌃⌘S toggles.
- Design review Major fixed: a retry that fails again synchronously (port in use, missing core) now
  shows and announces “仍然失败（第 N 次重试）”. Manage Profiles is hidden on Proxies.
- Checks run: full verify PASS 15 + 105 + 294 + 13 = 427; isolated probe frames viewed for 860 dark,
  1080 light, panel, hidden start, Reduce Motion and full screen; static re-render viewed.
- Probe used here (in-process window capture, no screen-recording permission):
  `/private/tmp/claude-501/-Users-spectreax-Developer-Veer-macos/a188dafe-3258-4a69-9054-4bbe0446c8cf/scratchpad/probe/`.
  It adapts Codex's `.codex/local/sidebar-followup/prepare.py` and `Probe.swift`.
- Follow-up from the user: closing toolbar groups ended as two thin glass lines. `RevealLayout` is
  gone; groups are inserted and removed inside the `GlassGroup` with `glassEffectID`, so they flow
  into and out of the neighbouring glass, matching the switch to Agent (opacity has no effect on
  glass drawn by the container). No official macOS 27 toolbar-transition guidance was found. Selected sidebar icons stay white only while the accent fill shows, so a
  background window no longer shows a white icon on grey. Frames and a background capture viewed
  (light); dark background NOT VERIFIED.
- Then the user asked for the closing groups to fade out like they fade in, not slide into the
  neighbour (seen switching to Tools). The groups' glass now uses `glassEffectTransition(.materialize)`:
  in and out both fade and blur in place. Frames viewed for Connections→Tools, Tools→Connections and
  Connections→Agent (1080, light, zh); verify.sh passed. Dark/en/narrow for this change and the
  real window NOT VERIFIED. dist/ rebuilt afterwards (SDK 27.2, minos 14.0, codesign ok); not launched.
- User request: an Agent conversation whose profile was deleted is archived and closed. `AgentStore.isArchived`
  is derived from whether the profile exists (no stored flag). Send, apply, discard, undo, redo, retry,
  clarification choices and the "split by network" link are blocked; the list has an "Archived" section and
  the composer is replaced by `ArchivedNotice` with "New Conversation". On the Agent page an archived chat
  stays readable even with no profile left (not rendered: NOT VERIFIED). Tests: `ArchivedConversationTests`.
  Snapshot scenes 09w/09x viewed (zh/en, light/dark, 1080/860) from an isolated copy with its own bundle id;
  verify.sh passed; apple-design-review: 2 Major fixed. Keyboard, VoiceOver, real window, macOS 14 NOT
  VERIFIED. Then archived chats fold into an "Archived (N)" `DisclosureGroup`, closed by default and open
  when the shown chat is archived (scene 09y added; viewed). dist/ rebuilt after quitting Veer; committed and pushed to PR #4.
- Known: a hidden system “Hide Sidebar ⌥⌘S” in the Help menu uses native toggleSidebar (present
  before too). The probe cannot see “Enter Full Screen” before or after the change.
- NOT VERIFIED: real app window, keyboard/VoiceOver, clicking a synchronously failing retry,
  macOS 14 VM, system proxy/TUN. `dist/Veer.app` was not rebuilt.

## Earlier state (2026-11-10, Claude)

The empty-group guard and sidebar-title fixes are committed; the page-content clipping remains
unresolved, so the full sidebar-glitch request is not finished. See PLAN's “边栏动画与启动错误”
section. Version stays 1.0.4 / build 5.

Codex status audit on 2026-11-10: the worktree was clean at `e085c98`; a read-only `git ls-remote`
confirmed the remote feature branch also points there. Both `d19cf01` (empty groups) and `e085c98`
(sidebar title) are therefore present remotely, superseding the earlier “not pushed” claim.
No push, build, app launch, test rerun or release was performed during this status audit.

- Empty-group guard (Codex's implementation) kept as written. The affected subscription still needs
  valid nodes from its provider.
- Sidebar title: Codex's uncommitted fix was replaced after frame-by-frame evidence showed it
  narrowed the sidebar and misaligned the title. The title now stays in the detail column and
  `ClearOfSidebarButton` sets its padding from the column's measured position. The detail-column
  `transaction` override was removed, as the frames showed no effect from it.
- Claude's completion-session checks (not rerun by the later status audit): full verify PASS,
  12 + 105 + 294 + 6 = 417 tests; isolated build with
  hide/show frame sheets for Overview, Proxies and Connections viewed; all scenes re-rendered and the
  related ones viewed; independent design review Critical 0 / Major 0, two Minor fixed.
- Known and left: content clips at the window's right edge for a frame or two while the sidebar
  shows (same before the change); the failure card's buttons don't match the empty-group advice.
- NOT VERIFIED: the real app window, full screen with the sidebar hidden, launch with the sidebar
  hidden, keyboard, VoiceOver, macOS 14 VM. Codex's temp logs and motion harness no longer exist.
- Later binary inspection supersedes the earlier old-build statement: `dist/Veer.app` contains
  `ClearOfSidebarButton`, `requireGroupMembers` and `startableText` symbols and the empty-group error
  text. Deep strict codesign verification PASS; minimum macOS 14.0 / SDK 27.2. Executable SHA-256:
  `58fc88f0883fe74d4f705298503077f5cbbce9860586af7467974732de8411dd`.
  Symbol checks establish that these fixes are included, not exact source/build correspondence.
- Next: fix page-content clipping during sidebar show, then verify full screen, rapid reversals
  and Reduce Motion using isolated sample data. Keep the outstanding manual checks above explicit.

## Latest feature completion (2026-11-01)

- Completed the inherited attachments, dedicated-group DIRECT handling, suggestion and proxy UI work.
  Fixed the review's loading/Return mismatch, full-permission DIRECT selection and missing-attachment
  recovery text. Added deterministic clipboard, size and sanitization regression coverage.
- DIRECT changes now remember the previous node for undo/redo, and delayed work checks profile and
  proposal status. A plan must exactly append DIRECT and be accepted; unrelated edits do not select it.
  Fixed local parsing of domains that contain an exit name (mini4k.net versus the mini4k group).
- Full verify PASS: 12 UI + 104 Proxy + 291 Core + 3 App = 410 tests. New App tests use a temporary
  data root and an independent pasteboard; the real Mihomo test has an explicit rejecting system-proxy
  runner, TUN off and an ephemeral port. It verifies apply → original node on undo → DIRECT on redo.
- Full verify log: `/private/tmp/veer-finish-verify.log` and `.codex/local/feature-verify.log`.
  The 404-test setup result below is historical, superseded by this feature verification.
- Independent design re-review: Critical 0, Major 0, Minor 0 in scope. 68/68 screenshots actually viewed;
  60 main-window images PASS, 8 native TUN alert captures NOT VERIFIED due to alpha compositing.
  Report: `macos/docs/reviews/2026-11-01-agent-attachments.md`.
- Signed development app: `macos/dist/Veer-agent-attachments-20261101.app`, Apple Development,
  deep strict codesign check PASS, deployment target 14.0 / SDK 27.2. It was not launched, and the
  person's real `dist/Veer.app` was not replaced. App version remains 1.0.4 / build 5; no release/tag.
- Subsequent user instruction: replace the app. Confirmed no target process was running, installed
  that signed development build as `macos/dist/Veer.app`, and retained the previous bundle as
  `macos/dist/Veer-before-agent-attachments-20261101.app`. Post-replacement strict signature and
  executable SHA-256 checks PASS. The replaced app was not launched; proxy/TUN state was not changed.
- Workflow setup and this feature are separate local commits; use `git log` for exact hashes.
  Nothing is pushed or published. No real API Key was read and no proxy/TUN toggle was used.
- Still NOT VERIFIED: real provider vision, live app drag/drop and Command-V, keyboard focus and
  VoiceOver, live window/fullscreen behavior, macOS 14 VM, real system proxy/TUN, full-turn automatic
  Hook execution and notarization. Do not interpret static or bridge tests as these manual checks.

## Claude's stopping point (historical evidence)

- Branch: `feat/macos-agent-attachments`; last commit `f122772`.
- Pending feature: Agent files/images, REJECT and IPv6 suggestion fixes, proxy layout and collapse
  animation fixes, and DIRECT handling for dedicated service groups.
- At handoff there were 22 tracked modified files and 5 new Swift files, all uncommitted.
- Claude's final full verify at 2026-11-01 17:16 Asia/Singapore exited 0: 12 + 104 + 288 = 404 tests.
  This is a historical result, not a claim that the current session ran these checks.
- Claude rendered screenshots, ran a design review, and applied follow-up fixes. Final independent
  review of those fixes still needs confirmation. Real-model vision, drag/drop and Command-V in
  the real app were explicitly untested; dist was not rebuilt.
- Claude's wrap-up said the changes were ready to discuss committing, then its final response
  hit the weekly limit. No commit was made for the feature.
- Local source session (private, never commit it):
  `~/.claude/projects/-Users-spectreax-Developer-Veer-macos/a188dafe-3258-4a69-9054-4bbe0446c8cf.jsonl`.
- Local historical artifacts:
  `/private/tmp/claude-501/-Users-spectreax-Developer-Veer-macos/a188dafe-3258-4a69-9054-4bbe0446c8cf/scratchpad/`.
  `verify-att.log` holds the final verification output. A missing temp artifact is NOT VERIFIED.

## Workflow migration (historical setup record)

Root AGENTS.md, project config, event adapters, four original project skill adapters and a native
reference router connect the existing rules and scripts. Environment and retained user decisions:
`macos/docs/WORKFLOW.md`. Machine-local archives and verification logs: ignored `.codex/local/`.

Migration setup is complete. Checks run in this session on 2026-11-01:

- Shared `verify.sh`: format, strict lint, build, 404 tests PASS (12 UI + 104 Proxy + 288 Core).
  Log: `.codex/local/verify.log`.
- Event adapter: 3 tests PASS; session-context injection and the shared Stop check exercised
  directly. Five skill definitions passed the bundled skill validator.
- Root and `macos/` instruction discovery checked with `codex debug prompt-input`.
  Both terminal CLI 0.162.1 and desktop CLI 0.166.0-alpha.5.1 discovered the five project skills
  and all three project Hooks without configuration errors.
- The three project Hooks were reviewed individually through CLI `/hooks` and enabled.
  Desktop CLI also reports them as enabled and trusted. Existing global/plugin Hook definitions
  and trust records were left as they were. No hook-trust bypass flag was used.
- Native lifecycle event execution across a full model turn remains NOT VERIFIED. Runtime
  discovery/trust and direct adapter execution are verified; do not imply that testing an
  adapter proves every automatic lifecycle event. The current chat read the same rules directly.
- Isolated release-form app build, SDK stamping and ad hoc signature verification PASS.
  Default screenshots PASS: 79 scenes × two languages × light/dark = 316 full images,
  plus 8 fullscreen left-region images, 324 PNGs total. Images checked for PNG headers and size.
  Four images were actually viewed as an environment smoke check: zh-Hans attachments light,
  zh-Hans long proxy names dark, en attachments light and dark. This was not a full feature audit.
- Snapshot root:
  `/private/var/folders/8b/9krhx4nn0bd2zz_0w21jj18c0000gn/T/veer-codex.qyvwAi/macos/dist/snapshots/2026-11-01-205826/`.
  Build and snapshot logs are in the enclosing isolated workspace; `.codex/local/snapshots.log`
  records their locations. The running real app was not rebuilt or replaced.
- Environment inventory: `.codex/local/environment.json`. GitHub CLI authenticated; Mihomo,
  Sparkle signing tools and Apple Development identity present. Developer ID absent;
  notarization, macOS 14 VM and live accessibility/network tests remain NOT VERIFIED.
- SHA-256 comparison confirms all pre-existing product source, test and design files retain
  their original content. The only existing macOS file changed by setup was the design-compliance
  README, correcting the stale claim that Xcode is not installed.
- `git diff --check` PASS. Environment changes and the pre-existing feature are uncommitted;
  nothing has been pushed or published. No system proxy or TUN was enabled.

Machine-readable evidence: `.codex/local/verification.json`. Before resuming feature work, read
actual Git status. Do not treat this handoff as permission to stage the pre-existing diff.

## Remaining acceptance work

1. User-only acceptance items are listed in the latest completion record and review report.
2. If they expose a defect, reproduce it in an isolated test environment, fix and reverify it.
3. Publish only after a separate user instruction and the complete release checklist.
