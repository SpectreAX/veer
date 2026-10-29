#!/bin/zsh
# Builds dist/Veer.app: the app plus the bundled Mihomo core it runs.
set -eu
cd "${0:A:h}/.."
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
# The core is not committed: scripts/build-mihomo.sh builds the pinned upstream tag that
# THIRD_PARTY_NOTICES.md names into vendor/mihomo. VEER_MIHOMO_BIN overrides it.
core="${VEER_MIHOMO_BIN:-$PWD/vendor/mihomo}"
if [[ ! -x "$core" ]]; then
  print -u2 "未找到 Mihomo 内核：$core"
  print -u2 "请先运行 scripts/build-mihomo.sh，或设置 VEER_MIHOMO_BIN。"
  exit 1
fi
lipo -verify_arch "$(uname -m)" "$core"
swift build -c release --product Veer
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Veer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/licenses"
cp "$bin_dir/Veer" "$app/Contents/MacOS/Veer"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Drawn by scripts/make-icon.swift; regenerate it there rather than editing the .icns.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$core" "$app/Contents/Resources/bin/mihomo"
cp third_party/mihomo/LICENSE "$app/Contents/Resources/licenses/mihomo-LICENSE"
cp .build/checkouts/Yams/LICENSE "$app/Contents/Resources/licenses/Yams-LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
cp LICENSE "$app/Contents/Resources/licenses/Veer-LICENSE"
codesign --force --sign - "$app/Contents/Resources/bin/mihomo"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print -r -- "$app"
