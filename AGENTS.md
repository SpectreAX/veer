# Veer development workflow

The macOS app is `macos/`. The legacy Android repository is archived in `android/deprecated/`;
it is historical reference, not an active development target. The older Veer AI Editor is a
separate repository. Keep platform code, builds and release processes separate. Legacy instructions
inside `android/deprecated/` apply only to that archived tree.

Before any macOS work, read `macos/CLAUDE.md` and every `macos/.claude/rules/*.md`.
These are the shared, authoritative development instructions for Claude and Codex; the name
`CLAUDE.md` does not limit their applicability. Read the matching module's `CLAUDE.md` before
editing it. Follow `macos/docs/WORKFLOW.md` for the environment, retained decisions and tool mapping.

Read `.codex/HANDOFF.md` when resuming unfinished work. Check the actual worktree before editing;
preserve existing changes and distinguish historical verification from checks run this session.
Update `macos/docs/PLAN.md` and the handoff after meaningful progress so either agent can resume.

Project skills are in `.agents/skills/`: `macos-feature`, `macos-visual-audit`,
`apple-design-review`, `macos-release-check`, and `veer-macos-reference`.
They adapt the existing Claude workflows; keep shared rules and checks in their original files.

Run commands from `macos/` unless a command says otherwise. Full verification is
`bash .claude/scripts/verify.sh`; Hooks only cover changed-file formatting and lint.
If Hooks have not loaded, run their checks explicitly. Never claim that a configured Hook ran
without evidence. See `.codex/scripts/workflow.py` for the Codex event adapter.

Never enable the system proxy or TUN, including through a fallback or restoring real app state.
Never launch the real app for tests. For current-code screenshots, use
`bash .codex/scripts/snapshots.sh` from the repository root: it builds a separate copy.
Do not replace a running app. Publishing a release requires the user's explicit go-ahead each time.
