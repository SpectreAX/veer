#!/bin/bash
# Stop hook: format and lint on the Swift files with uncommitted changes. It does not build or test.
# Stdout must hold only the JSON answer, so tool output goes to a variable.
set -uo pipefail
. "$(dirname "$0")/env.sh"

INPUT="$(cat)"

FILES=()
while IFS= read -r file; do
  case "$file" in
    Sources/*.swift | Tests/*.swift) [ -f "$file" ] && FILES+=("$file") ;;
  esac
done < <(git diff --name-only --relative HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

[ "${#FILES[@]}" -gt 0 ] || exit 0

OUTPUT=""
STATUS=0
for tool in swiftformat swiftlint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    OUTPUT="$tool is not installed. Run: brew install swiftformat swiftlint"
    STATUS=1
  fi
done
if [ "$STATUS" -eq 0 ]; then
  OUTPUT="$(swiftformat "${FILES[@]}" --lint --quiet 2>&1)" || STATUS=1
  LINT="$(swiftlint lint --strict --quiet "${FILES[@]}" 2>&1)" || STATUS=1
  OUTPUT="$OUTPUT"$'\n'"$LINT"
fi

[ "$STATUS" -eq 0 ] && exit 0

# Block once. On the retry let Claude stop, so a problem it cannot fix cannot trap the session,
# and tell the user the check is still failing.
INPUT="$INPUT" OUTPUT="$OUTPUT" python3 -c '
import json, os
active = json.loads(os.environ["INPUT"] or "{}").get("stop_hook_active", False)
details = os.environ["OUTPUT"].strip()[:4000]
if active:
    print(json.dumps({"systemMessage": "Format or lint is still failing on changed Swift files:\n" + details}))
else:
    print(json.dumps({"decision": "block", "reason": "Fix these format and lint failures, do not suppress them. If one cannot be fixed, report it as unresolved.\n" + details}))
'
