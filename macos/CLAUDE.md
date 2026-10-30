# Veer for macOS: development rules

Veer is a native macOS proxy client: SwiftUI on Mihomo, with an AI agent for routing changes.
Apple's Human Interface Guidelines are the design authority. Where Veer departs from them, the
reason is written down in [DESIGN_SPEC.md](DESIGN_SPEC.md).

Read these before changing the matching area:

- Behavior of every page: [docs/SPEC.md](docs/SPEC.md). Requirements: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).
- Design: [DESIGN_SPEC.md](DESIGN_SPEC.md), [Design/TOKENS.md](Design/TOKENS.md), [Design/COMPONENTS.md](Design/COMPONENTS.md).
- Code layout and state: [ARCHITECTURE.md](ARCHITECTURE.md).
- Rules for Swift files load from `.claude/rules/` when those files are opened.

## Commands

```bash
bash .claude/scripts/verify.sh              # format, lint, build, test
bash .claude/scripts/verify.sh --lint-only  # format and lint only
scripts/build-app.sh                        # dist/Veer.app, built the way it ships
scripts/snapshots.sh                        # every screen, light and dark, zh and en
```

This machine has Command Line Tools only, no Xcode: `xcodebuild`, Instruments, XCUITest and
`.xcstrings` are not available. Do not suggest them as the next step.

## Non-negotiable

1. Prefer SwiftUI. Use AppKit only when SwiftUI cannot do the job, and say why in a comment.
2. Prefer system controls. A custom control needs an entry in [Design/COMPONENTS.md](Design/COMPONENTS.md).
3. Follow macOS conventions, not iOS ones.
4. Page code uses `VeerUI` tokens and styles. APIs that exist only on macOS 26 stay inside `VeerUI`,
   behind `#available`: the minimum system is macOS 14 and there is one build.
5. Support light and dark, zh-Hans and en, keyboard use and VoiceOver.
6. Never claim something passed unless it ran. An unchecked result is NOT VERIFIED.
7. Do not weaken lint rules, regenerate the baseline, or edit tests to get a pass.

## Safety on this Mac

- Never turn on Veer's system proxy or TUN, and never trigger a path that does. Both reroute the
  whole Mac, including this session. List those checks for the user instead.
- Launching `dist/Veer.app` without `VEER_SNAPSHOT_DIR` runs on the user's real data and restores
  their last state, which can start the core and the proxy. Use `scripts/snapshots.sh`.
- A failed build leaves the old binary in `dist/`, so never chain a run after a build with `;`.
- `scripts/build-app.sh` deletes and replaces `dist/Veer.app`. Check that the app is not open first.
- A binary copied by hand from `.build/` skips the SDK stamp in `build-app.sh` and runs the
  pre-macOS 26 design, so results from it do not describe what ships.
- UI automation is unreliable in this app. Prefer API-level checks and never automate near
  destructive menus.
- Publishing a release needs the user's go-ahead every time. See [docs/RELEASE.md](docs/RELEASE.md).
- Mihomo is GPL-3.0 and runs only as a separate process over HTTP. Do not link it in.

## When a change is done

Every change:

1. `bash .claude/scripts/verify.sh` passes.
2. New logic has unit tests.
3. New Chinese strings have English in `Resources/Localization/en.lproj`. `LocalizationTests` checks this.

A change that touches UI also needs:

4. `/macos-visual-audit`, with the screenshots actually looked at.
5. `/apple-design-review`, with every Critical and Major finding fixed.
6. A macOS 14 VM check if the look changed. Only the user can run this: list it as NOT VERIFIED.

The hooks are a floor, not the check: they cover format and lint on changed files only, and never
build, test or look at the interface.

## Final report

State what changed, what ran and its result, what the review found, any remaining deviations, and
what still needs a person. Mark anything not run as NOT VERIFIED.
