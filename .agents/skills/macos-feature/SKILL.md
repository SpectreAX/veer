---
name: macos-feature
description: Implement a feature or substantial UI change in Veer's native macOS app, using the shared project rules and verification workflow.
---

Read `macos/.claude/skills/macos-feature/SKILL.md` from the repository root and follow it.
Use the user's current request as its feature argument. Resolve its paths and commands from `macos/`.
Read root `AGENTS.md` and `macos/docs/WORKFLOW.md` for the retained decisions and Codex tool mapping.
Use `$macos-visual-audit` and `$apple-design-review` for its UI checks. Only a user request to
approve the design first creates a design approval gate. Preserve existing work.
