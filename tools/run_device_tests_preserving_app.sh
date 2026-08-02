#!/usr/bin/env bash
set -euo pipefail

# Runs instrumentation on a shared physical device without Gradle's connected
# task uninstalling com.yamax.veer (which would erase profiles and credentials).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
SERIAL="${ANDROID_SERIAL:-}"
TARGET_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="$ROOT_DIR/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
TARGET_PACKAGE="com.yamax.veer"
TEST_PACKAGE="com.yamax.veer.test"
RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"

adb_cmd() {
    if [[ -n "$SERIAL" ]]; then
        "$ADB" -s "$SERIAL" "$@"
    else
        "$ADB" "$@"
    fi
}

cd "$ROOT_DIR"
./gradlew assembleDebug assembleDebugAndroidTest

# -r preserves target data and VPN consent. Never use connectedDebugAndroidTest
# against a shared user device: AGP uninstalls the target package afterwards.
adb_cmd install -r -t "$TARGET_APK"
adb_cmd install -r -t "$TEST_APK"

result_file="$(mktemp -t veer-device-tests.XXXXXX)"
cleanup() {
    adb_cmd uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || true
    rm -f "$result_file"
}
trap cleanup EXIT

set +e
adb_cmd shell am instrument -w -r "$RUNNER" | tee "$result_file"
instrument_status=${PIPESTATUS[0]}
set -e

if [[ $instrument_status -ne 0 ]] ||
    rg -q 'FAILURES!!!|INSTRUMENTATION_FAILED|INSTRUMENTATION_ABORTED' "$result_file" ||
    ! rg -q '^OK \([0-9]+ tests?\)$' "$result_file"; then
    echo "Device tests failed; target app data was preserved." >&2
    exit 1
fi

echo "Device tests passed; $TARGET_PACKAGE remains installed with its data preserved."
