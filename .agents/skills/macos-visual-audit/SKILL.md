---
name: macos-visual-audit
description: Inspect real Veer macOS screenshots across sizes, themes, languages and states after UI changes or for a visual audit.
---

Read `macos/.claude/skills/macos-visual-audit/SKILL.md` and follow its matrix and reporting rules.
Use the current request as its scope; resolve source paths from `macos/`.
For current-source renders run `bash .codex/scripts/snapshots.sh` from the repository root.
This replaces its in-place build instructions and works while the real Veer app is open.
Open every relevant PNG with `view_image`; a filename or successful render is not visual evidence.
Keep keyboard, VoiceOver, live window behavior and macOS 14 NOT VERIFIED without runtime evidence.
