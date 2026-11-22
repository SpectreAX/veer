#!/bin/bash
# Build and render the current macOS sources without replacing the user's running app.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp/}veer-codex.XXXXXX")"
echo "Isolated workspace: $work"
mkdir -p "$work/macos"
rsync -a --exclude=.build --exclude=dist --exclude=vendor \
  "$repo/macos/" "$work/macos/"
mkdir -p "$work/macos/vendor"
core="${VEER_MIHOMO_BIN:-$repo/macos/vendor/mihomo}"
if [ ! -x "$core" ]; then
  echo "Mihomo is missing; build it with macos/scripts/build-mihomo.sh first." >&2
  exit 1
fi
ln -s "$core" "$work/macos/vendor/mihomo"
cd "$work/macos"
# Keep SwiftUI and AppKit preferences in a snapshot-only domain.
plutil -replace CFBundleIdentifier -string com.yamax.veer.snapshots Resources/Info.plist
# Snapshot-only copy: ad hoc signing avoids accessing the user's signing keys.
VEER_SIGN_IDENTITY=- scripts/build-app.sh > "$work/build.log" 2>&1 || {
  tail -60 "$work/build.log" >&2
  exit 1
}
# snapshots.sh checks the binary's snapshot marker and sets VEER_SNAPSHOT_DIR before launch.
scripts/snapshots.sh > "$work/snapshots.log" 2>&1 || {
  tail -60 "$work/snapshots.log" >&2
  exit 1
}
cat "$work/snapshots.log"
echo "Build log: $work/build.log"
