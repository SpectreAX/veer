---
name: apple-design-review
description: Independently review Veer macOS UI changes against Apple HIG, the design spec and real rendered evidence, and report severity and verification gaps.
---

Read `macos/.claude/skills/apple-design-review/SKILL.md` and follow its evidence, categories,
severity and enforcement rules. Use the current request as its scope; resolve paths from `macos/`.
Its Claude `context: fork` means an independent review: use a read-only subagent for that review,
passing the scope and raw evidence without the author's conclusions. The reviewer must not modify
files, launch the real app, touch proxy/TUN or publish. The parent handles confirmed fixes.
Use `bash .codex/scripts/snapshots.sh` at the repo root for current-source renders and `view_image`
for PNGs. Fetch Apple HIG JSON using `macos/Design/HIG_REFERENCES.md`.
Report unavailable independent or runtime evidence as NOT VERIFIED, never as PASS.
