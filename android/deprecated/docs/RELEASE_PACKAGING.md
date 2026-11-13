# Veer Release packaging

Last updated: 2026-07-29.

## One-command build

Run from the repository root:

```shell
tools/release/package_release.sh
```

The command produces:

```text
build/release-artifacts/
  Veer-v{version}-arm64-v8a.apk
  Veer-v{version}-armeabi-v7a.apk
  Veer-v{version}-x86_64.apk
  Veer-v{version}-universal.apk
  Veer-v{version}.aab
  Veer-v{version}-SHA256SUMS.txt
```

When no Release identity is configured, each APK/AAB filename includes
`-unsigned`. Those artifacts are suitable for static inspection or local
test-signing only and must not be distributed.

The R8 mapping remains at:

```text
app/build/outputs/mapping/release/mapping.txt
```

Archive it privately with the matching release. Do not publish it with GitHub
Release assets.

## Why the wrapper performs two Gradle builds

AGP 9.2.1 cannot build ABI-split APKs and an AAB in the same Gradle invocation
when resource shrinking is enabled. It reports multiple shrunk-resource files
to `buildReleasePreBundle`.

The wrapper keeps one user command but deliberately executes:

1. `./gradlew -Pveer.abiSplits=true :app:assembleRelease`
2. `./gradlew :app:bundleRelease`

The APKs are copied before the second invocation. Both invocations use the same
working tree, version and Release variant. Normal `assembleDebug` and
`assembleRelease` calls remain single-output builds unless the split property
is explicitly enabled.

## Production signing

Never store a keystore or password in this repository. The `.gitignore` already
excludes `*.jks` and `*.keystore`.

Preferred developer configuration is
`~/.gradle/gradle.properties`:

```properties
veer.release.storeFile=/absolute/protected/path/veer-release.jks
veer.release.storePassword=...
veer.release.keyAlias=...
veer.release.keyPassword=...
```

CI can provide the equivalent secret environment variables:

```text
VEER_RELEASE_STORE_FILE
VEER_RELEASE_STORE_PASSWORD
VEER_RELEASE_KEY_ALIAS
VEER_RELEASE_KEY_PASSWORD
```

All four values are required together. A partial configuration fails during
Gradle configuration. For every candidate/public build, require signed output:

```shell
VEER_REQUIRE_SIGNED=1 tools/release/package_release.sh
```

This gate rejects the artifact set if any APK or the AAB is unsigned.

## Automatic checks

The packaging command:

- requires exactly arm64-v8a, armeabi-v7a, x86_64 and Universal APK outputs;
- verifies every single-ABI APK contains only its declared native directory;
- verifies Universal contains exactly the three supported ABIs and no x86;
- assigns versioned deterministic filenames;
- generates SHA-256 values for all four APKs and the AAB;
- immediately runs `shasum -c` against the generated manifest;
- labels unsigned output and optionally rejects it.

Before upload, additionally verify signed candidates with Android Build Tools
and the JDK:

```shell
apksigner verify --verbose --print-certs Veer-v{version}-arm64-v8a.apk
jarsigner -verify Veer-v{version}.aab
shasum -a 256 -c Veer-v{version}-SHA256SUMS.txt
```

All four APK certificate SHA-256 digests must be identical.

## Runtime release matrix

Required before a public release:

| Artifact | Required environment | Status on 2026-07-29 |
|---|---|---|
| arm64-v8a | Android 10+ arm64 device/emulator | Passed on Android 16 arm64 |
| Universal | Android 10+ arm64 and x86_64 | Passed on Android 16 arm64 |
| x86_64 | Android 10+ x86_64 emulator/device | Pending: no local x86_64 AVD |
| armeabi-v7a | Real or emulated 32-bit ARM | Pending: no local armv7 runtime |
| AAB | Bundle signing and store/internal sharing validation | Build/signing path passed; store validation pending |

Every runtime row must cover installation, app launch, profile activation, VPN
Running, controller `/version`, and real HTTP 204 through Mihomo. Static ABI
inspection or Universal success cannot substitute for a missing architecture
runtime.
