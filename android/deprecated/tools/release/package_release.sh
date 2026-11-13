#!/usr/bin/env bash
#
# Builds all Veer sideload artifacts from one source state.
#
# AGP 9.2 cannot build ABI-split APKs and an AAB in the same Gradle invocation
# when resource shrinking is enabled. This wrapper intentionally performs two
# isolated invocations while exposing one deterministic release command.
#
# Usage:
#   tools/release/package_release.sh [Gradle options]
#
# Release signing is read by app/build.gradle.kts from ~/.gradle/gradle.properties
# or VEER_RELEASE_* environment variables. Set VEER_REQUIRE_SIGNED=1 in CI to
# reject unsigned output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GRADLEW="$ROOT_DIR/gradlew"
APK_DIR="$ROOT_DIR/app/build/outputs/apk/release"
BUNDLE_DIR="$ROOT_DIR/app/build/outputs/bundle/release"
METADATA="$APK_DIR/output-metadata.json"
OUTPUT_DIR="${VEER_RELEASE_OUTPUT_DIR:-$ROOT_DIR/build/release-artifacts}"
REQUIRE_SIGNED="${VEER_REQUIRE_SIGNED:-0}"

mkdir -p "$OUTPUT_DIR"
find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type f -delete

echo "[release] Building ABI APKs"
"$GRADLEW" "$@" -Pveer.abiSplits=true :app:assembleRelease

if [[ ! -f "$METADATA" ]]; then
    echo "[release] Missing APK metadata: $METADATA" >&2
    exit 1
fi

VERSION_NAME="$(
    python3 - "$METADATA" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    metadata = json.load(stream)
versions = {str(element["versionName"]) for element in metadata["elements"]}
if len(versions) != 1:
    raise SystemExit(f"Expected one versionName, found: {sorted(versions)}")
print(versions.pop())
PY
)"

EXPECTED_ABIS="arm64-v8a,armeabi-v7a,x86_64"
APK_COUNT=0
UNSIGNED_COUNT=0

while IFS=$'\t' read -r classifier output_file; do
    source_apk="$APK_DIR/$output_file"
    if [[ ! -f "$source_apk" ]]; then
        echo "[release] Missing APK declared by metadata: $source_apk" >&2
        exit 1
    fi

    signature_suffix=""
    if [[ "$output_file" == *-unsigned.apk ]]; then
        signature_suffix="-unsigned"
        UNSIGNED_COUNT=$((UNSIGNED_COUNT + 1))
    fi

    target_apk="$OUTPUT_DIR/Veer-v${VERSION_NAME}-${classifier}${signature_suffix}.apk"
    cp "$source_apk" "$target_apk"

    actual_abis="$(
        unzip -Z1 "$target_apk" |
            awk -F/ '$1 == "lib" && NF == 3 && $3 ~ /[.]so$/ {print $2}' |
            LC_ALL=C sort -u |
            paste -sd, -
    )"
    expected_abis="$classifier"
    if [[ "$classifier" == "universal" ]]; then
        expected_abis="$EXPECTED_ABIS"
    fi
    if [[ "$actual_abis" != "$expected_abis" ]]; then
        echo "[release] ABI mismatch for $(basename "$target_apk")" >&2
        echo "[release] expected=$expected_abis actual=$actual_abis" >&2
        exit 1
    fi

    APK_COUNT=$((APK_COUNT + 1))
done < <(
    python3 - "$METADATA" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    metadata = json.load(stream)
for element in metadata["elements"]:
    if element["type"] == "UNIVERSAL":
        classifier = "universal"
    else:
        abi_filters = [
            item["value"]
            for item in element["filters"]
            if item["filterType"] == "ABI"
        ]
        if len(abi_filters) != 1:
            raise SystemExit(f"Unexpected APK filters: {element['filters']}")
        classifier = abi_filters[0]
    print(f"{classifier}\t{element['outputFile']}")
PY
)

if [[ "$APK_COUNT" -ne 4 ]]; then
    echo "[release] Expected four APKs, found $APK_COUNT" >&2
    exit 1
fi

echo "[release] Building Android App Bundle in a separate AGP invocation"
"$GRADLEW" "$@" :app:bundleRelease

source_aab="$BUNDLE_DIR/app-release.aab"
if [[ ! -f "$source_aab" ]]; then
    echo "[release] Missing AAB: $source_aab" >&2
    exit 1
fi

aab_signature_suffix=""
if ! unzip -Z1 "$source_aab" |
    grep -E '^META-INF/[^/]+[.](RSA|DSA|EC)$' >/dev/null; then
    aab_signature_suffix="-unsigned"
    UNSIGNED_COUNT=$((UNSIGNED_COUNT + 1))
fi
target_aab="$OUTPUT_DIR/Veer-v${VERSION_NAME}${aab_signature_suffix}.aab"
cp "$source_aab" "$target_aab"

if [[ "$REQUIRE_SIGNED" == "1" && "$UNSIGNED_COUNT" -ne 0 ]]; then
    echo "[release] Refusing $UNSIGNED_COUNT unsigned artifacts (VEER_REQUIRE_SIGNED=1)" >&2
    exit 1
fi

checksum_file="$OUTPUT_DIR/Veer-v${VERSION_NAME}-SHA256SUMS.txt"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 Veer-v"${VERSION_NAME}"-*.apk Veer-v"${VERSION_NAME}"*.aab \
        > "$(basename "$checksum_file")"
    shasum -a 256 -c "$(basename "$checksum_file")"
)

if [[ "$UNSIGNED_COUNT" -ne 0 ]]; then
    echo "[release] WARNING: $UNSIGNED_COUNT artifacts are unsigned and not distributable"
fi
echo "[release] Mapping retained at app/build/outputs/mapping/release/mapping.txt"
echo "[release] Artifacts:"
find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort
