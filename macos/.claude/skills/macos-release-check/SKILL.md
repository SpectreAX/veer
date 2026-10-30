---
name: macos-release-check
description: Run a strict pre-release quality and Apple HIG check for the macOS app. Use before a release.
disable-model-invocation: true
---

# macOS release check

This check reports. Change code only if the user asks. Never publish: `scripts/release.sh --publish`
needs the user's go-ahead every time.

## Checks

1. Read the diff since the last release tag.
2. Run `bash .claude/scripts/verify.sh`.
3. Confirm the version and build number went up in `Resources/Info.plist`.
4. Run `/macos-visual-audit` on what changed since the last release.
5. Run `/apple-design-review` on the same range.
6. Check that accessibility is covered on changed screens.
7. Check deployment target compatibility: macOS 26 APIs stay in `VeerUI`.
8. Check that `THIRD_PARTY_NOTICES.md` matches what ships.
9. Go through `docs/RELEASE.md` and list every step marked for the user. Do not perform those steps.

## Release blockers

- Build failure or a failing test
- A Critical or Major HIG violation
- A known severe accessibility defect
- An unresolved data-loss or destructive-action defect

## Report

Give PASS, FAIL or NOT VERIFIED for each check, with the command or evidence behind it. Never turn
NOT VERIFIED into PASS. Anything that needs the proxy, TUN or the macOS 14 VM is NOT VERIFIED until
the user has run it.
