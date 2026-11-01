# Sourced by the other scripts: moves to the project root and finds the tools.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

# Hooks may start without the login shell's PATH.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Without Xcode, SwiftLint cannot find sourcekitd unless it is told where the toolchain is.
if [ -z "${TOOLCHAIN_DIR:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  export TOOLCHAIN_DIR=/Library/Developer/CommandLineTools
fi
