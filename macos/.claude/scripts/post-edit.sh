#!/bin/bash
# PostToolUse hook: formats the edited Swift file, then lints it.
# Exit 2 is what shows stderr to Claude; any other failure would stay hidden from it.
set -uo pipefail
. "$(dirname "$0")/env.sh"

FILE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"

case "$FILE" in
  "$ROOT"/Sources/*.swift | "$ROOT"/Tests/*.swift) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

for tool in swiftformat swiftlint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not installed, so $FILE was not checked. Run: brew install swiftformat swiftlint" >&2
    exit 2
  fi
done

swiftformat "$FILE" --quiet >&2 || exit 2
swiftlint lint --strict --quiet "$FILE" >&2 || exit 2
