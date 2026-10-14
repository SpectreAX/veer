#!/bin/zsh
set -eu
cd "${0:A:h}/.."
source_dir="$PWD/../../prototype/ai-editor"
node_bin="${VEER_NODE_BIN:-$(command -v node || true)}"
validator="$source_dir/.cache/mihomo"
arch="$(uname -m)"
[[ -n "$node_bin" && -x "$node_bin" && -x "$validator" ]] || { print -u2 '需要自包含 Node 与已构建的本机 Mihomo 校验器。'; exit 1; }
node_version="$("$node_bin" -p 'process.versions.node')"
license="Resources/Licenses/node-v$node_version-LICENSE"
[[ -f "$license" ]] || { print -u2 "缺少 Node $node_version 的许可文本：$license"; exit 1; }
[[ -f "$source_dir/node_modules/yaml/package.json" && -f "$source_dir/node_modules/diff/package.json" ]] || { print -u2 '请先在 prototype/ai-editor 运行 npm ci。'; exit 1; }
# Homebrew Node may require dylibs outside the app; reject rather than ship a broken bundle.
if otool -L "$node_bin" | awk '/compatibility version/ && $1 !~ /^\/(usr\/lib|System\/Library)\// {bad=1} END {exit !bad}'; then
  print -u2 'Node 依赖外部 dylib。请通过 VEER_NODE_BIN 指定官方自包含 Node。'; exit 1
fi
lipo -verify_arch "$arch" "$node_bin"
lipo -verify_arch "$arch" "$validator"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Veer AI Editor.app"
# Start from an empty bundle so files removed from the sources are not shipped and signed.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/VeerMac" "$app/Contents/MacOS/VeerMac"
cp Resources/Info.plist "$app/Contents/Info.plist"
editor="$app/Contents/Resources/editor"
mkdir -p "$editor/bin" "$editor/node_modules" "$editor/licenses"
cp "$source_dir/server.mjs" "$source_dir/native-host.mjs" "$source_dir/package.json" "$editor/"
ditto "$source_dir/core" "$editor/core"
for dependency in yaml diff; do
  ditto "$source_dir/node_modules/$dependency" "$editor/node_modules/$dependency"
done
if [[ "$(lipo -archs "$node_bin")" == "$arch" ]]; then
  cp "$node_bin" "$editor/bin/node"
else
  lipo "$node_bin" -thin "$arch" -output "$editor/bin/node"
fi
cp "$validator" "$editor/bin/mihomo"
cp ../../go_core/third_party/mihomo/LICENSE "$editor/licenses/mihomo-LICENSE"
cp "$license" "$editor/licenses/node-LICENSE"
"$node_bin" -p 'JSON.stringify({node:process.version,architecture:process.arch})' > "$editor/runtime.json"
"$editor/bin/node" --help >/dev/null
codesign --force --sign - "$editor/bin/node"
codesign --force --sign - "$editor/bin/mihomo"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print -r -- "$app"
