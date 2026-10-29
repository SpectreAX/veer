#!/bin/zsh
# Builds dist/Veer-<version>.dmg: Veer.app beside a link to Applications. With
# VEER_NOTARY_PROFILE set (a `xcrun notarytool store-credentials` profile; needs a Developer ID
# build), the DMG is notarized and stapled too.
set -eu
cd "${0:A:h}/.."
scripts/build-app.sh >/dev/null
app="$PWD/dist/Veer.app"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
dmg="$PWD/dist/Veer-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Veer.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Veer" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
identity="$(codesign -dvv "$app" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')"
[[ -n "$identity" ]] && codesign --force --timestamp=none --sign "$identity" "$dmg"
if [[ -n "${VEER_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$VEER_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi
print -r -- "$dmg"
