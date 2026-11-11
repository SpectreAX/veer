# Design specification

Veer should feel like a first-party Mac app. [docs/SPEC.md](docs/SPEC.md) section 10 records the
visual decisions; this file gives the priorities and the deviations.

## Priorities

1. Native usability
2. Platform consistency
3. Accessibility
4. Information hierarchy
5. Visual refinement
6. Brand expression

Brand expression must not damage native usability.

## Window

- Standard window controls, resizing and full screen.
- Minimum 860 × 560, default 1080 × 720 (`Metrics`). Below 1100 wide the layout goes compact.
- The empty space in the top row moves the window; a double click follows the system setting.
- Full screen is the system's. The top row stays, and the sidebar button moves into the place of the
  window buttons, which the system shows with the menu bar when the pointer reaches the top.

## Navigation

- `NavigationSplitView` sidebar in two groups: Proxy and AI.
- `⌘1`–`⌘5` switch the sidebar's pages. Tools has subpages with a back button and `⌘[`. Important
  commands are also in the menu bar.
- The Agent panel is a plain column beside the page.

## Toolbar

- Icon-only buttons have accessibility labels and tooltips.
- Controls are grouped by what they do, each group in its own glass, and at most three groups: up to
  two for the page, with search on its own, then the Agent toggle and start/stop together.
- The last group stays fixed. A group grows out of its neighbour on the same spring rather than
  appearing on its own.
- The profile's name under the title is the profile menu, as the HIG places a document menu.
- A toggle in the toolbar fills when on, and says its state to VoiceOver.
- Search is `⌘F`; Esc clears it and leaves the field.

## Typography

System fonts and semantic text styles. Code and logs use `Typography.code` and `codeSmall`.

## Color

- Semantic system colors and `VeerUI` tokens only. Check light and dark.
- Never carry meaning by color alone: `StatusKind` is always icon plus text.
- Colors Veer chooses are at least 4.5:1 for text, measured from real renders where glass is involved, as it lightens what it
  is tinted with. Green behind a label or check is `accentFill` with `onAccent`; green as text or a
  glyph on the page is `veerAccent`. They differ in dark, as no one green does both.
- Green is for small areas: primary actions, the node in use, written state. System controls such
  as segmented pickers keep the system's own colors.

## Materials

- Glass belongs to controls and navigation. Content panels (`panel()`) stay solid.
- Page code uses `primaryAction()`, `secondaryAction()` and `floatingPanel()`, which fall back to
  standard styles on macOS 14 and 15. It does not call `glassEffect`.

## Motion

`Motion.quick` and `Motion.standard`, or a documented spring. With Reduce Motion on, only fade.
`CoreStateRing` around the Overview's start button turns once in 1.1 s while the core starts, and its
ripple takes 0.6 s: state feedback, not a transition, with a steady ring and no ripple under Reduce Motion.

## Components and interaction

- Prefer `Button`, `Toggle`, `Picker`, `List`, `Table`, sheets, alerts and context menus.
- One primary action per page.
- Runtime actions run at once and can be undone. Config changes need an Apply click on a diff card.
- Destructive actions use the standard confirmation pattern.

## Language

Simplified Chinese is the source text and English translates it, in `.strings` files. Layouts must
hold both: English runs longer.

## Documented deviations

Each entry is a known, deliberate departure from the system default. Reviews should not report one
as a violation unless its reason no longer holds. Anything not listed here is not excused.

| Deviation | Why | Where |
|---|---|---|
| The system toolbar stays empty and the controls float above it | With items in `NSToolbar`, opening the sidebar pushes them into the `»` overflow, and they jump instead of animating between pages | SPEC 5, `PageToolbar`, `ToolbarCapsule` |
| The window has no toolbar at all in full screen | AppKit moves a toolbar to a window of its own in front of the content, which covers the floating controls, and entering full screen shows it again if it is hidden | SPEC 5, `EmptyWindowToolbar` |
| Proxies' add button shares a glass group with the view controls | A group of its own would make four, and the HIG asks for at most three | SPEC 5, `ProxiesView` |
| Own glass switch instead of a segmented picker in the top row | Outside a real toolbar, which Veer leaves empty, the system's picker draws its own track instead of glass. The selection is a neutral shape, so it does not use the system accent | SPEC 5, `GlassSwitch` |
| Back button floats in the top row instead of `NavigationStack` | A stack's back button belongs to the system toolbar, which Veer leaves empty | SPEC 5, `MainView` |
| "Later" instead of "Cancel" in the TUN helper alert | It puts the install off rather than calling anything off, and Esc still works. The wording is the product owner's | SPEC 4.1, `HelperPrompt` |
| Sidebar selection stays in the accent color when the focus moves | Pages put the cursor in their own field, and the system's dimming then flashes between two looks on every click. The product owner asked for one look | SPEC 5, `selectionHighlight` |
| Own search field instead of `.searchable` | Several `.searchable` pages crash `NSToolbar` with a duplicate identifier on page switch (1.0.3 crash) | SPEC 5, `ToolbarSearchField` |
| Sidebar hides and shows by moving the native split view's divider, not through `NavigationSplitView`'s own collapse | Its collapse reused a stale page image, and reversing it mid-way in an 860-wide window grew the window to 1040. SwiftUI has no control of the divider, so `SidebarAnimator` drives the split view item it already has; with Reduce Motion it switches at once | `SidebarAnimator`, `MainView` |
| Plain Agent column instead of `.inspector` | `NSSplitViewController` throws if the inspector changes mid-animation (crash on 2026-10-30) | `AgentPanelColumn` |
| Veer green tint instead of the system accent color | Brand color, used only on small areas. Custom accent colors are out of scope for v1 | `Color.veerAccent` |
| Fixed chart palette | Categorical colors need stable, color-blind-checked pairs that the system colors do not give. Every chart has a legend with exact counts | `ChartPalette` |
| `.strings` instead of String Catalog | Chosen before Xcode was installed; the existing localization and checks still use it, and a migration is not scheduled | SPEC 9 |
| Carbon `RegisterEventHotKey` for global shortcuts | The only system API for them without a third-party library. Unbound by default | SPEC 8, `HotKeys` |

## Acceptance

Major UI changes are reviewed from real rendered output. Reading source alone cannot establish
visual compliance, and a screenshot cannot establish keyboard or VoiceOver behavior.
