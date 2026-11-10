---
name: macos-release-check
description: Run Veer's read-only pre-release verification, visual and HIG review, and release checklist when a release check is explicitly requested.
---

Read `macos/.claude/skills/macos-release-check/SKILL.md` and follow it from `macos/`.
Use `$macos-visual-audit` and `$apple-design-review` for its named reviews.
Use the existing `macos/scripts/release.sh`, not a generic archive or release pipeline.
Report only; code fixes require authorization and publishing requires the user's go-ahead each time.
