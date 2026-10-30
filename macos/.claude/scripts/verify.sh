#!/bin/bash
# Format, lint, build and test the whole project. `--lint-only` stops after lint.
# SwiftPM projects are detected. For an Xcode project set SCHEME and PROJECT or WORKSPACE.
set -euo pipefail
. "$(dirname "$0")/env.sh"

for tool in swiftformat swiftlint; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed. Run: brew install swiftformat swiftlint" >&2; exit 1; }
done

# Project-specific environment for the tests, if the project needs any.
[ -f .claude/verify.env ] && . .claude/verify.env

echo "[1/4] SwiftFormat"
swiftformat . --lint --quiet

echo "[2/4] SwiftLint"
swiftlint lint --strict --quiet

if [ "${1:-}" = "--lint-only" ]; then
  echo "Format and lint passed. Build and tests were not run."
  exit 0
fi

if [ -f Package.swift ]; then
  echo "[3/4] swift build"
  swift build
  echo "[4/4] swift test"
  swift test
elif [ -n "${SCHEME:-}" ] && { [ -n "${WORKSPACE:-}" ] || [ -n "${PROJECT:-}" ]; }; then
  container=(-project "${PROJECT:-}")
  [ -n "${WORKSPACE:-}" ] && container=(-workspace "$WORKSPACE")
  echo "[3/4] xcodebuild build"
  xcodebuild "${container[@]}" -scheme "$SCHEME" -destination 'platform=macOS' build
  echo "[4/4] xcodebuild test"
  xcodebuild "${container[@]}" -scheme "$SCHEME" -destination 'platform=macOS' test
else
  echo "ERROR: no Package.swift, and SCHEME with PROJECT or WORKSPACE is not set. Build and tests did not run." >&2
  exit 1
fi

echo "Passed: format, lint, build, tests. This says nothing about how the interface looks or behaves."
