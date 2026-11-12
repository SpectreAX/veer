#!/bin/bash
# Builds ios/VeerMobileKit/Vendor/MihomoCore.xcframework (ios-arm64 + ios-arm64-simulator):
# the pinned, unmodified upstream Mihomo tag, linked in-process through the cgo wrapper in
# ios/core (-buildmode=c-archive).
#
# LICENCE: this makes the iOS prototype a GPL-3.0 combined work. The owner approved that only for
# the undistributed Simulator prototype. Never ship a build that contains this framework.
#
# Runs on macOS with Xcode. Idempotent: skips the build when the framework exists and its stamp
# matches the recipe hash (this script, ios/core sources, the pin, Go and Xcode versions).
# VEER_FORCE_REBUILD=1 rebuilds anyway; VEER_NO_CACHE=1 skips airbuild-cache restores.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ios_dir="$(pwd)"
self="$ios_dir/scripts/$(basename "${BASH_SOURCE[0]}")"

tag=v1.19.29
commit=e26714a181ac0e2fa803453c0a8e9a9ce94e31cb
# No extra tags: no TUN stack (with_gvisor) is needed for a local mixed port + controller.
go_tags=""
min_ios=26.0

vendor_dir="$ios_dir/VeerMobileKit/Vendor"
out="$vendor_dir/MihomoCore.xcframework"
stamp="$vendor_dir/MihomoCore.stamp"
build_dir="$ios_dir/build"          # git-ignored; go.mod's replace points at build/mihomo
src="$build_dir/mihomo"

if ! command -v go >/dev/null 2>&1; then
  brew install go
fi
# Use the installed toolchain; never download another one behind our back.
export GOTOOLCHAIN=local

have_cache=0
if command -v airbuild-cache >/dev/null 2>&1 && [ -z "${VEER_NO_CACHE:-}" ]; then
  have_cache=1
fi

recipe="$(
  {
    cat "$self"
    for f in "$ios_dir"/core/go.mod "$ios_dir"/core/go.sum "$ios_dir"/core/*.go "$ios_dir"/core/include/*; do
      [ -f "$f" ] && { echo "== ${f#"$ios_dir"/}"; cat "$f"; }
    done
    echo "$tag $commit [$go_tags] $min_ios"
    go version
    xcodebuild -version
  } | shasum -a 256 | awk '{print $1}'
)"
echo "MihomoCore recipe: $recipe"

if [ "$have_cache" = 1 ] && [ ! -d "$out" ]; then
  airbuild-cache restore --key "veer-ios-mihomocore-$recipe" --path "$vendor_dir" ||
    echo "warning: airbuild-cache restore of MihomoCore failed; building" >&2
fi
if [ -z "${VEER_FORCE_REBUILD:-}" ] && [ -d "$out" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$recipe" ]; then
  echo "MihomoCore.xcframework is up to date ($out)"
  exit 0
fi

if [ "$have_cache" = 1 ]; then
  airbuild-cache restore --key veer-ios-mihomo-go-v1 \
    --path "$(go env GOMODCACHE)" --path "$(go env GOCACHE)" ||
    echo "warning: airbuild-cache restore of the Go caches failed; continuing cold" >&2
fi

# Pinned source, verified like macos/scripts/build-mihomo.sh.
mkdir -p "$build_dir"
if [ ! -d "$src/.git" ] || [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
  rm -rf "$src"
  git clone --quiet --depth 1 --branch "$tag" https://github.com/MetaCubeX/mihomo.git "$src"
fi
actual="$(git -C "$src" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
  echo "Mihomo $tag points at $actual, not $commit; the tag may have moved. Stopping." >&2
  exit 1
fi
if [ -n "$(git -C "$src" status --porcelain)" ]; then
  echo "The Mihomo clone in $src has local changes; it must be unmodified. Stopping." >&2
  exit 1
fi

cd "$ios_dir/core"
if [ ! -f go.sum ]; then
  # Bootstrap only: resolves exactly the versions the pinned Mihomo go.mod requires.
  # Commit the resulting go.sum; later builds use it read-only and verify against it.
  echo "ios/core/go.sum missing: running go mod tidy (commit the result)" >&2
  go mod tidy
fi
go mod verify

go version
xcodebuild -version
slices="$build_dir/slices"
rm -rf "$slices"
build_slice() {
  local sdk="$1" target="$2" dir="$3" sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  mkdir -p "$dir"
  echo "Building $target ($sysroot)"
  env CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    CC="$(xcrun --sdk "$sdk" --find clang)" \
    CXX="$(xcrun --sdk "$sdk" --find clang++)" \
    CGO_CFLAGS="-isysroot $sysroot -target $target -O2" \
    CGO_LDFLAGS="-isysroot $sysroot -target $target" \
    go build -mod=readonly -buildmode=c-archive -trimpath -buildvcs=false -tags "$go_tags" \
    -ldflags "-X \"github.com/metacubex/mihomo/constant.Version=$tag\" -w -s -buildid=" \
    -o "$dir/libMihomoCore.a" .
  # The Go-generated header must export what include/MihomoCore.h declares.
  local fn
  for fn in VeerCoreStart VeerCoreStop VeerCoreValidate VeerCoreVersion VeerCoreFree; do
    grep -q "extern .* $fn(" "$dir/libMihomoCore.h" || {
      echo "Generated header lacks $fn" >&2
      exit 1
    }
  done
  rm "$dir/libMihomoCore.h"
}
build_slice iphoneos "arm64-apple-ios$min_ios" "$slices/ios-arm64"
build_slice iphonesimulator "arm64-apple-ios$min_ios-simulator" "$slices/ios-arm64-simulator"

# Headers live in a MihomoCore/ subfolder so the module map cannot collide with other
# frameworks' module maps when Xcode merges headers; clang finds <dir>/MihomoCore/module.modulemap.
headers="$build_dir/headers"
rm -rf "$headers"
mkdir -p "$headers/MihomoCore"
cp "$ios_dir/core/include/MihomoCore.h" "$ios_dir/core/include/module.modulemap" "$headers/MihomoCore/"

mkdir -p "$vendor_dir"
tmp="$build_dir/xcframework/MihomoCore.xcframework"
rm -rf "$tmp"
mkdir -p "$(dirname "$tmp")"
xcodebuild -create-xcframework \
  -library "$slices/ios-arm64/libMihomoCore.a" -headers "$headers" \
  -library "$slices/ios-arm64-simulator/libMihomoCore.a" -headers "$headers" \
  -output "$tmp"
rm -rf "$out"
mv "$tmp" "$out"
echo "$recipe" >"$stamp"
echo "Built $out"
du -sh "$out"/*/libMihomoCore.a
