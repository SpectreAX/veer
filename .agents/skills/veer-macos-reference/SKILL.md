---
name: veer-macos-reference
description: Consult the original Claude macOS API, design, settings or Sparkle reference skills while working on Veer, or resolve an explicitly named original macos-* skill.
---

Read `macos/docs/WORKFLOW.md` for the original reference skill locations and tool mapping.
Load only the matching original `SKILL.md` and its relevant supporting files. They remain available
on this Mac under `~/.claude/skills/`; project-specific workflows live under `macos/.claude/skills/`.
Project rules and actual code take precedence over those generic references. Veer is SwiftPM,
minimum macOS 14, and already has settings, Sparkle, signing and release scripts. Do not generate
an Xcode project, replace its settings scene, regenerate signing keys or publish to follow a template.
For `/macos-build`, use `bash .claude/scripts/verify.sh` from `macos/`; app packaging uses
`scripts/build-app.sh` only after checking the target app is not running, or the isolated snapshot
script at the repo root. Missing references must be reported, not silently substituted.
