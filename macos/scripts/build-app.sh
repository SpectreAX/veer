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
swift build -c release --product VeerHelper
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Veer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/licenses" "$app/Contents/Frameworks" \
  "$app/Contents/Library/LaunchServices" "$app/Contents/Library/LaunchDaemons"
cp "$bin_dir/Veer" "$app/Contents/MacOS/Veer"
# SwiftPM records the deployment target (14.0) as the SDK version too, and macOS only gives
# apps built with the macOS 26 SDK its current design (Liquid Glass). Record the real one.
min_os="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
sdk_version="$(xcrun --sdk "$SDKROOT" --show-sdk-version)"
vtool -set-build-version macos "$min_os" "$sdk_version" -replace -output "$app/Contents/MacOS/Veer" "$app/Contents/MacOS/Veer"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Drawn by scripts/make-icon.swift; regenerate it there rather than editing the .icns.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Interface strings: Simplified Chinese is the source text, English translates it.
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
# Country outlines for the node map (Natural Earth, public domain).
cp -R Resources/Map "$app/Contents/Resources/Map"
cp "$core" "$app/Contents/Resources/bin/mihomo"
cp third_party/mihomo/LICENSE "$app/Contents/Resources/licenses/mihomo-LICENSE"
cp .build/checkouts/Yams/LICENSE "$app/Contents/Resources/licenses/Yams-LICENSE"
# Sparkle (MIT) for updates; the executable finds it through @executable_path/../Frameworks.
ditto "$bin_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/licenses/Sparkle-LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
cp LICENSE "$app/Contents/Resources/licenses/Veer-LICENSE"
# TUN's privileged helper, registered through SMAppService from this plist.
helper_label=com.yamax.veer.helper
cp "$bin_dir/VeerHelper" "$app/Contents/Library/LaunchServices/$helper_label"
cat > "$app/Contents/Library/LaunchDaemons/$helper_label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$helper_label</string>
  <key>BundleProgram</key><string>Contents/Library/LaunchServices/$helper_label</string>
  <key>MachServices</key><dict><key>$helper_label</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>com.yamax.veer</string></array>
</dict>
</plist>
PLIST
# The helper accepts only callers and cores signed by its own team, so everything is signed
# with one identity: VEER_SIGN_IDENTITY, else the first Apple Development certificate. Without
# one the app is signed ad hoc and TUN is unavailable.
identity="${VEER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$identity" ]]; then
  print -u2 "没有找到 Apple Development 证书，改用临时签名，TUN 将不可用。"
  identity=-
fi
# A Developer ID build is notarized: that needs the hardened runtime and a secure timestamp.
if [[ "$identity" == "Developer ID Application"* ]]; then
  stamp=(--timestamp) runtime=(--options runtime)
else
  stamp=(--timestamp=none) runtime=()
fi
flags=("${stamp[@]}" "${runtime[@]}")
codesign --force "${flags[@]}" --sign "$identity" "$app/Contents/Resources/bin/mihomo"
# Sparkle's helpers inside out, then the framework (its own documented order).
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for item in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
            "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
  [[ -e "$item" ]] && codesign --force "${stamp[@]}" --options runtime --preserve-metadata=entitlements --sign "$identity" "$item"
done
codesign --force "${stamp[@]}" --options runtime --sign "$identity" "$sparkle"
codesign --force "${flags[@]}" --sign "$identity" --identifier "$helper_label" "$app/Contents/Library/LaunchServices/$helper_label"
codesign --force "${flags[@]}" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
print -r -- "$app"
