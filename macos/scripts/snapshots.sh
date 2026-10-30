#!/bin/zsh
# Renders every SnapshotRunner scene from dist/Veer.app into dist/snapshots/<date>/<language>/.
# Sample data only: it never starts a core or touches the system proxy, but windows appear briefly.
# VEER_SNAPSHOT_LANGUAGES and VEER_SNAPSHOT_APPEARANCE narrow it, e.g. en and light.
set -eu
cd "${0:A:h}/.."

binary="$PWD/dist/Veer.app/Contents/MacOS/Veer"
# A binary without snapshot mode would run on the user's real data and restore their last state.
if [[ ! -x "$binary" ]] || ! strings "$binary" | grep -q VEER_SNAPSHOT_DIR; then
  print -u2 "dist/Veer.app 不存在或不支持截图模式，请先运行 scripts/build-app.sh。"
  exit 1
fi

newer="$(find Sources Resources -type f -newer "$binary" | head -1)"
if [[ -n "$newer" ]]; then
  print -u2 "警告：$newer 比 dist/Veer.app 新，截图反映的不是最新代码。"
fi

out="$PWD/dist/snapshots/$(date +%Y-%m-%d-%H%M%S)"
for language in ${(s:,:)${VEER_SNAPSHOT_LANGUAGES:-zh-Hans,en}}; do
  mkdir -p "$out/$language"
  VEER_SNAPSHOT_DIR="$out/$language" "$binary" -AppleLanguages "($language)"
done
print -r -- "$out"
