# Veer

Veer is an Android Mihomo VPN client built with Kotlin, Jetpack Compose, and a
Go gomobile bridge.

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
