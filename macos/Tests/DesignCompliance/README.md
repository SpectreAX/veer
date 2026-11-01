# Design compliance

No test target lives here. This records what each kind of check can and cannot show.

| Check | Tool | Covers | Cannot cover |
|---|---|---|---|
| Static | `verify.sh --lint-only`, including the design rules in `.swiftlint.yml` | Raw colors, glass outside `VeerUI`, fixed font sizes, literal spacing, the banned `.searchable` and `.inspector` | Whether a design is any good |
| Unit | `swift test`, including `LocalizationTests` | Logic, and that every Chinese string has English | Appearance |
| Rendered | `scripts/snapshots.sh` | Each scene in light and dark, zh-Hans and en | Transitions, live window drags, keyboard, VoiceOver |
| Review | `/macos-visual-audit`, `/apple-design-review` | Comparison against the HIG and the design spec | It is a judgment, not Apple certification |
| By a person | `docs/RELEASE.md` | Keyboard, VoiceOver, macOS 14 VM, system proxy, TUN | |

XCUITest needs Xcode, which this machine does not have.

## Acceptance

Critical 0, Major 0, automated tests all passing, visual review done. Minor findings may stay if the
reason and plan are recorded.

Record the macOS version, app build, window size, appearance and language with screenshots. A
screenshot does not replace VoiceOver testing, and reading source does not replace running the app.
