---
name: macos-visual-audit
description: Audit real macOS app screenshots across window sizes, appearance modes, languages and interaction states. Use after a UI change, or when asked whether a screen looks right.
argument-hint: "[scene names or a page; default is the scenes the diff touches]"
---

# macOS visual audit

Scope: $ARGUMENTS

Review real output, not just source.

## Get the screenshots

1. Check that `dist/Veer.app` was built after the latest change. If not, and the app is not open, run
   `scripts/build-app.sh` and confirm it succeeded before going on.
2. Run `scripts/snapshots.sh`. It renders sample data in a throwaway directory and never starts a core
   or touches the system proxy. Windows appear briefly on screen.
3. Read each relevant PNG with the Read tool. A scene you did not open counts as NOT VERIFIED.

If a state in the diff has no scene, add one to `Sources/VeerApp/SnapshotRunner.swift` rather than
launching the real app.

## Review matrix

| Scenario | Required |
|---|---|
| Standard window | Yes |
| Narrow window, down to the 860 × 560 minimum | Yes |
| Wide window | Yes |
| Light and dark | Yes |
| zh-Hans and en | Yes |
| Sidebar visible and hidden | If applicable |
| Agent panel open and closed | If applicable |
| Empty and error states | If applicable |
| Important sheets and dialogs | If applicable |

## Inspect

Alignment, hierarchy, clipping, overflow, resizing, contrast, typography, materials, control
consistency and focus visibility. English strings run longer than Chinese ones, so look for truncation.

## Report

Record the macOS version, window size, appearance, language and state for what you checked. Separate:

- Confirmed defects
- HIG violations
- Visual inconsistencies
- Subjective suggestions
- Not verified scenarios

Screenshots cannot cover keyboard or VoiceOver behavior, page transitions, live window drags, or
macOS 14. List those as NOT VERIFIED for the user.
