---
paths:
  - "**/*.swift"
  - "Tests/**"
---

# Testing and verification

Never claim a check passed unless it ran in this session.

- `bash .claude/scripts/verify.sh` runs format, lint, build and tests.
- Visual review uses real rendered output. Record the OS version, window size, appearance, language
  and state for each screenshot.
- If runtime access is unavailable, mark the result NOT VERIFIED. NOT VERIFIED is never PASS.
- A screenshot does not prove keyboard or VoiceOver behavior.
- Do not weaken a test or lint rule to hide a defect.
