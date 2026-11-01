# Veer macOS handoff

## Scope

Shared progress summary: [`macos/docs/PLAN.md`](../macos/docs/PLAN.md), section
“本轮开发收尾（2026-11-01，Codex）”. Update that document and this handoff after meaningful progress,
as the user requested, so Claude can resume through its usual development-plan entrypoint.

2026-11-01: after workflow migration the user authorized finishing Claude's remaining development.
The feature and workflow are being recorded as separate local commits. Publishing, enabling the
system proxy, and TUN tests on the real Mac remain outside authorization.

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
