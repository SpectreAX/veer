# Architecture

[docs/SPEC.md](docs/SPEC.md) section 1 has the full layout and data directory. In short:

| Target | Job | Rules |
|---|---|---|
| `VeerCore` | Config parsing, AI rule editing, validation, controller client | No UI. A separate copy from veer-editor; port fixes by hand when both need them |
| `VeerUI` | Design tokens and shared components | The only place for macOS 26 APIs and raw colors |
| `VeerProxy` | Mihomo process, runtime config, profiles, system proxy | No UI, testable |
| `VeerHelperKit` | XPC protocol, paths, signature checks shared with the helper | Small |
| `VeerHelper` | Root daemon that runs Mihomo for TUN | Small on purpose: no YAML, no AI. Bump `HelperConstants.version` when it changes |
| `VeerApp` | SwiftUI app: window, menu bar, settings, Agent | Views and stores |

Dependencies point one way: `VeerApp` → `VeerUI`, `VeerProxy` → `VeerCore`. Do not add a new
dependency for something Apple's frameworks already do.

## State

- Shared state lives in `@Observable` stores (`ProxyStore`, `AgentStore`) passed by `.environment`.
- `@State` is for view-local state. Keep one source of truth.
- Slow work stays off the main thread. `VeerApp` and `VeerUI` default to `MainActor` isolation.
- AI and manual routing edits are operations replayed over the raw subscription (`EditReplay`). An
  operation that fails is reported, never dropped silently.

## SwiftUI

- Keep views focused and extract real reusable pieces into `VeerUI`.
- Avoid `AnyView` and `GeometryReader` unless the layout needs them. `SnapshotRunner` uses `AnyView`
  to hold a list of scenes.
- Handle empty, loading, error and populated states. `StateView` covers the first three.

## AppKit

Isolate each bridge in a small `NSViewRepresentable` and say why it exists, as `WindowDragArea` does.
Do not leak AppKit types through the rest of the app.

## Compatibility

Minimum macOS 14. Check availability for anything newer, and put macOS 26 APIs in `VeerUI`.
SwiftPM records the deployment target as the SDK version, so `scripts/build-app.sh` stamps the real
SDK with `vtool`. Without that stamp the app runs in the old design.
