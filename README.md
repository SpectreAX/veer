# Veer

Veer currently focuses on a privacy-conscious AI configuration editor: import
a Mihomo configuration, propose service-routing changes, review destinations
and Diff, confirm to a draft, and export a copy. The macOS interface is native
SwiftUI; it does not start or control a VPN. The earlier Android Mihomo client
remains in this repository for future full-client development.

## Native rebuild (2026-10-17)

A ground-up native macOS rebuild lives in [`native/macos-editor`](native/macos-editor/README.md):
one Swift process with no Node runtime and no listening ports, built from the spec
[`docs/VEER_AI_EDITOR_SPEC_2026-10-17.md`](docs/VEER_AI_EDITOR_SPEC_2026-10-17.md) and the Open Design
prototype in [`prototype/editor-rebuild`](prototype/editor-rebuild/README.md). The older editor below is kept
for comparison until the rebuild replaces it.

## Current editor development (2026-10-14)

- Native macOS: [`native/macos/README.md`](native/macos/README.md).
- Local editing service: [`prototype/ai-editor/README.md`](prototype/ai-editor/README.md).
- Interactive UI reference: [`prototype/opencode-review/README.md`](prototype/opencode-review/README.md).
- Latest implementation and verification: [`docs/MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md`](docs/MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md).

The native UI now uses a main conversation and collapsible change-review pane,
with a single review region in narrow windows. Configuration secrets stay local;
AI receives anonymous routing context. Confirmation changes only the draft,
not a running proxy. Current verification: 29 Swift tests, Release build and
ad-hoc signature checks, plus scoped native UI validation. Real AI requests,
older macOS/accessibility runtime checks and public distribution notarization
were not verified in this round. The `.app` now bundles its own editor service,
Node runtime, dependencies and rule validator: no external `npm start` is
required. It uses an authenticated random loopback port and stops its owned
service on exit. This remains an ad-hoc development build, not a notarized
public distribution. See [`docs/MACOS_BUNDLED_SERVICE_2026-10-14.md`](docs/MACOS_BUNDLED_SERVICE_2026-10-14.md).

Build from `native/macos` with `zsh scripts/build-app.sh`. Output is
`native/macos/dist/Veer AI Editor.app` relative to **this checkout**, not to an
older workspace directory. On the current development machine the verified
path is `/Users/spectreax/Developer/Veer/native/macos/dist/Veer AI Editor.app`.
Build outputs and dependencies are excluded from Git; a fresh checkout must
build the application locally.

## Android client (retained development)

Built with Kotlin, Jetpack Compose and a Go gomobile bridge.

- Package: `com.yamax.veer`
- Minimum Android version: Android 10 (API 29)
- Toolchain: JDK 21, Go, Android NDK r27d
- Runtime: Mihomo v1.18.10 through `libveer_core.aar`

## Current capabilities

- Start and stop the Android `VpnService` with serialized native lifecycle
- Import Clash YAML from a file, pasted text, or an HTTPS subscription URL
- Validate, normalize, persist, activate, refresh, rename, and delete profiles
- Generate an Android-safe Mihomo TUN configuration
- Use the local Mihomo controller for health checks and proxy selection
- Apply AI-generated routing overrides through a rule provider

Open the project in Android Studio with Gradle JDK 21. For command-line builds:

```shell
./gradlew testDebugUnitTest lintDebug assembleDebug
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`.
Runtime constraints and current verification status are documented in
[`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md).

To build the three per-ABI Release APKs, Universal APK, AAB, and SHA-256
manifest from one source state:

```shell
tools/release/package_release.sh
```

Unsigned local output is labeled `-unsigned`. Production signing setup and
release verification are documented in
[`docs/RELEASE_PACKAGING.md`](docs/RELEASE_PACKAGING.md).
