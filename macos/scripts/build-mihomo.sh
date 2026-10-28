#!/bin/zsh
# Builds the bundled Mihomo validator, unmodified, from a pinned upstream tag into vendor/mihomo,
# so THIRD_PARTY_NOTICES.md can name its exact corresponding source.
set -eu
cd "${0:A:h}/.."
tag=v1.19.29
commit=e26714a181ac0e2fa803453c0a8e9a9ce94e31cb
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet --depth 1 --branch "$tag" https://github.com/MetaCubeX/mihomo.git "$work/mihomo"
actual="$(git -C "$work/mihomo" rev-parse HEAD)"
if [[ "$actual" != "$commit" ]]; then
  print -u2 "Mihomo $tag 指向 $actual，而不是 $commit；标签可能被改动，已停止。"
  exit 1
fi
mkdir -p vendor
# Same flags as upstream's Makefile, so the binary matches an official build of the tag.
(cd "$work/mihomo" && CGO_ENABLED=0 go build -tags with_gvisor -trimpath \
  -ldflags "-X \"github.com/metacubex/mihomo/constant.Version=$tag\" -w -s -buildid=" \
  -o "$work/vendor-mihomo.tmp" .)
mv "$work/vendor-mihomo.tmp" vendor/mihomo
vendor/mihomo -v
