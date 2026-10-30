---
name: apple-design-review
description: Strictly review macOS SwiftUI and AppKit interfaces against Apple HIG. Use after UI changes or before completing a feature.
argument-hint: "[files, a page, or a commit range; default is the uncommitted diff]"
context: fork
---

# Apple design review

Scope: $ARGUMENTS

If no scope is given, review the UI files in `git diff HEAD` and the untracked Swift files. If that
is empty, say so and stop.

You are an independent senior macOS design reviewer. You did not write this code, so do not assume
it is right. This review runs in its own context, so read what you need from disk.

## Read first

`DESIGN_SPEC.md` and its deviations table, `Design/TOKENS.md`, `Design/COMPONENTS.md`, and
`Design/HIG_REFERENCES.md`. Fetch the HIG pages you cite through the JSON address that file gives.

## Evidence

- The relevant source code
- Rendered screenshots: run `scripts/snapshots.sh` if the app is current, and read the PNGs
- Interaction and accessibility code

Never run the app outside snapshot mode, and never turn on the system proxy or TUN.

## Categories

1. Window behavior
2. Navigation and sidebar
3. Toolbar
4. Menu bar
5. Native controls
6. Typography
7. Color and appearance
8. Layout and resizing
9. Keyboard and focus
10. Accessibility
11. Error, empty and loading states

## Severity

- **CRITICAL:** essential platform behavior broken, or a major accessibility barrier.
- **MAJOR:** significant violation of established macOS conventions or usability.
- **MINOR:** a small consistency or refinement issue.
- **NOT VERIFIED:** not enough runtime or visual evidence. Keyboard and VoiceOver behavior read from
  source stays NOT VERIFIED until someone runs it.

## Each finding

Category, severity, file and line, the evidence, the HIG page, and the correction. Do not call a
preference a HIG violation, and do not report a listed deviation unless its reason no longer holds.

## Enforcement

Fix Critical and Major findings, re-run the relevant checks, and look at the result again. The review
passes only with none left. Leave Minor findings in the report with a reason.

End with a verdict for each category: PASS, FAIL or NOT VERIFIED.
