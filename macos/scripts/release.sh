#!/bin/zsh
# Prepares a release: the DMG, its Sparkle signature and dist/appcast.xml with this version.
# Nothing leaves this Mac unless --publish is given; then both go to a GitHub release
# v<version> on SpectreAX/veer-releases, where SUFeedURL reads releases/latest/download/appcast.xml.
#   scripts/release.sh [--notes notes.html] [--publish]
set -eu
cd "${0:A:h}/.."
notes="" publish=false
while (( $# )); do
  case "$1" in
    --notes) notes="$(cat "$2")"; shift 2 ;;
    --publish) publish=true; shift ;;
    *) print -u2 "未知参数：$1"; exit 1 ;;
  esac
done
repo=SpectreAX/veer-releases
dmg="$(scripts/make-dmg.sh)"
info="$PWD/dist/Veer.app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$info")"
build="$(plutil -extract CFBundleVersion raw "$info")"
minimum="$(plutil -extract LSMinimumSystemVersion raw "$info")"
# The EdDSA key generate_keys stored in the login keychain under this account.
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account com.yamax.veer "$dmg")"
url="https://github.com/$repo/releases/download/v$version/${dmg:t}"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Veer</title>
    <item>
      <title>Veer $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <description><![CDATA[$notes]]></description>
      <enclosure url="$url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
print -r -- "$dmg"
print -r -- "$PWD/dist/appcast.xml"
if $publish; then
  gh release create "v$version" "$dmg" dist/appcast.xml --repo "$repo" --title "Veer $version" --notes "${notes:-Veer $version}"
fi
