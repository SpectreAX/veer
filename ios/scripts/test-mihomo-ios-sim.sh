#!/bin/bash
# Proves MihomoCore.xcframework links and runs in the iOS Simulator: builds a Swift harness
# (import MihomoCore, autolinked frameworks) and a C harness (explicit link flags) against the
# simulator slice, runs them with `xcrun simctl spawn`, and checks the controller and the mixed
# port from the host. Only 127.0.0.1 ports 17891/19091; the host system proxy is never touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ios_dir="$(pwd)"
min_ios=26.0
target="arm64-apple-ios$min_ios-simulator"
xcf="$ios_dir/VeerMobileKit/Vendor/MihomoCore.xcframework"
slice="$xcf/ios-arm64-simulator"
work="$ios_dir/build/simtest"
secret=veer-harness-secret

[ -f "$slice/libMihomoCore.a" ] || { echo "Missing $slice; run scripts/build-mihomo-ios.sh" >&2; exit 1; }
for port in 17891 19091; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $port is already in use on this Mac; stopping." >&2
    exit 1
  fi
done
rm -rf "$work"
mkdir -p "$work"
sysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"

echo "== Slice platforms (LC_BUILD_VERSION of archive members; 2 = iOS, 7 = iOS Simulator)"
for s in ios-arm64 ios-arm64-simulator; do
  echo "$s: $(otool -l "$xcf/$s/libMihomoCore.a" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; f=0}' | sort | uniq -c | tr '\n' ' ')"
done

echo "== Swift harness (import MihomoCore; frameworks autolinked from module.modulemap)"
xcrun --sdk iphonesimulator swiftc -target "$target" -O \
  -I "$slice/Headers" -L "$slice" -lMihomoCore \
  "$ios_dir/scripts/mihomo-sim-harness.swift" -o "$work/harness-swift"

echo "== C harness (explicit: -framework CoreFoundation -framework Security -lresolv)"
cat >"$work/harness.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "MihomoCore.h"
int main(void) {
  char *v = VeerCoreVersion();
  char *ok = VeerCoreValidate("mixed-port: 17891\nproxies: []\nrules:\n  - MATCH,DIRECT\n");
  char *bad = VeerCoreValidate("rules:\n  - MATCH,missing-proxy\n");
  printf("C harness: version=%s good=%s bad=%s\n", v, ok ? ok : "NULL", bad ? bad : "NULL");
  int pass = v && strcmp(v, "v1.19.29") == 0 && ok == NULL && bad != NULL;
  VeerCoreFree(v); VeerCoreFree(ok); VeerCoreFree(bad);
  puts(pass ? "C HARNESS RESULT: PASS" : "C HARNESS RESULT: FAIL");
  return pass ? 0 : 1;
}
EOF
xcrun --sdk iphonesimulator clang -target "$target" -isysroot "$sysroot" \
  -I "$slice/Headers/MihomoCore" "$work/harness.c" "$slice/libMihomoCore.a" \
  -framework CoreFoundation -framework Security -lresolv -o "$work/harness-c"

# A simulator to spawn in: a booted iPhone, else an existing one on the newest iOS runtime
# (booted, then shut down after), else a new one (deleted after).
created="" booted=""
pick="$(xcrun simctl list -j | python3 -c '
import json,sys
j=json.load(sys.stdin)
rts=[r for r in j["runtimes"] if r.get("isAvailable") and r.get("platform")=="iOS"]
rts.sort(key=lambda r:[int(x) for x in r["version"].split(".")])
devs=j["devices"]
for rt,ds in devs.items():
    for d in ds:
        if d["state"]=="Booted" and d["name"].startswith("iPhone"): print("booted",d["udid"]); sys.exit()
for r in reversed(rts):
    for d in devs.get(r["identifier"],[]):
        if d.get("isAvailable") and d["name"].startswith("iPhone"): print("existing",d["udid"]); sys.exit()
for r in reversed(rts):
    ts=[t["identifier"] for t in r.get("supportedDeviceTypes",[]) if t["name"].startswith("iPhone")]
    if ts: print("create",ts[-1],r["identifier"]); sys.exit()
print("none")')"
echo "Simulator choice: $pick"
set -- $pick
case "$1" in
  booted) udid="$2" ;;
  existing) udid="$2"; xcrun simctl boot "$udid"; booted="$udid" ;;
  create)
    udid="$(xcrun simctl create veer-core-harness "$2" "$3")"
    created="$udid"
    xcrun simctl boot "$udid"
    booted="$udid"
    ;;
  *) echo "No usable iOS Simulator runtime" >&2; xcrun simctl list runtimes; exit 1 ;;
esac
cleanup() {
  [ -n "${harness_pid:-}" ] && kill "$harness_pid" 2>/dev/null || true
  [ -n "$booted" ] && xcrun simctl shutdown "$booted" 2>/dev/null || true
  [ -n "$created" ] && xcrun simctl delete "$created" 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl list devices | grep "$udid"

echo "== Run C harness in the simulator"
xcrun simctl spawn "$udid" "$work/harness-c"

echo "== Run Swift harness in the simulator"
xcrun simctl spawn "$udid" "$work/harness-swift" "$work" >"$work/harness.log" 2>&1 &
harness_pid=$!
for _ in $(seq 1 300); do
  [ -f "$work/ready" ] && break
  kill -0 "$harness_pid" 2>/dev/null || break
  sleep 0.2
done
host_fail=0
if [ -f "$work/ready" ]; then
  hcheck() {
    local name="$1" expect="$2" out
    shift 2
    out="$(curl -sS --max-time 5 --noproxy '' "$@" 2>&1 || true)"
    if [[ "$out" == *"$expect"* ]]; then echo "PASS host: $name -> $out"; else echo "FAIL host: $name -> $out"; host_fail=1; fi
  }
  hcheck "controller /version" '"version":"v1.19.29"' -H "Authorization: Bearer $secret" http://127.0.0.1:19091/version
  hcheck "controller /version, wrong secret" 'Unauthorized' -H "Authorization: Bearer nope" http://127.0.0.1:19091/version
  hcheck "HTTP proxy via mixed-port (DIRECT to the controller)" '"version":"v1.19.29"' \
    -x http://127.0.0.1:17891 -H "Authorization: Bearer $secret" http://127.0.0.1:19091/version
  hcheck "SOCKS5 via mixed-port (DIRECT to the controller)" '"version":"v1.19.29"' \
    --socks5 127.0.0.1:17891 -H "Authorization: Bearer $secret" http://127.0.0.1:19091/version
  hcheck "controller /rules" '"proxy":"DIRECT"' -H "Authorization: Bearer $secret" http://127.0.0.1:19091/rules
else
  echo "FAIL host: harness never became ready"
  host_fail=1
fi
touch "$work/continue"
harness_status=0
wait "$harness_pid" || harness_status=$?
harness_pid=""
cat "$work/harness.log"
echo "Swift harness exit status: $harness_status; host checks: $([ $host_fail = 0 ] && echo PASS || echo FAIL)"
[ "$harness_status" = 0 ] && [ "$host_fail" = 0 ]
