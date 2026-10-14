#!/bin/zsh
set -eu
cd "${0:A:h}/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Veer AI Editor.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/VeerMac" "$app/Contents/MacOS/VeerMac"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
print -r -- "$app"
