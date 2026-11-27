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
- The Agent can also be in a window of its own (experimental, `AgentWindow`): a standard `Window`
  scene, not a panel, with its own corners, shadow, traffic lights, resizing, minimize, full screen and
  Stage Manager. Default 520 × 720, minimum 380 × 420 below the toolbar. It first opens on the main
  window's screen, beside the main window or over its trailing edge, wholly on screen; its frame is
  saved and put back on a screen when a display goes. Always on Top is in the Window menu, off by
  default, and raises only this window (`NSWindow.level`). It stays out of state restoration and the
  main window's tabs. One process and one Dock icon.

## Navigation

- `NavigationSplitView` sidebar in two groups: Proxy and AI.
- `⌘1`–`⌘5` switch the sidebar's pages. Tools has subpages with a back button and `⌘[`. Important
  commands are also in the menu bar.
- The Agent panel is a floating glass surface of its own beside the page (continuous 16 pt corners, regular Liquid Glass on macOS 26 and later, the regular material with a hairline edge before it; no fill, edge or shadow of Veer's on the glass), below the toolbar's row and 8 pt clear of it, the window's edges and the page. It is laid out with the page by one SwiftUI layout. Opening
  and closing animate both together on one spring; the window keeps its size.
- The Agent is hidden, docked (the panel) or detached (its window), one at a time
  (`AgentPresentation`). The panel header's "Open in Separate Window" closes the panel with its usual
  motion and shows the same conversation in the window; "Dock to Main Window" in the window's toolbar
  closes the window and opens the panel the same way. Nothing is re-sent: both show one `AgentStore`.
  Closing the window hides the Agent; the toolbar's Agent button brings an open window forward, or the
  last place back. While detached, the Agent page shows a pointer to the window in place of the
  conversation, so only one conversation and one composer are ever on screen.
- The Proxies page's top-row switch has three views: grid, map and App Routing. App Routing works
  with the core stopped, so the switch is available whenever there is a profile.

## Toolbar

- The menu bar shows Veer's own mark, the app icon's route and branch without its body, as a template image the system tints (`MenuBarMark`); it is dimmed while the core is not running.
- Icon-only buttons have accessibility labels and tooltips.
- Controls are grouped by what they do, each group in its own glass, and at most three groups: up to
  two for the page, with search on its own, then the Agent toggle and start/stop together.
- The last group stays fixed. On a page switch a group that comes or goes fades and blurs in place,
  glass and all, the same way in and out; one that stays springs to its new width.
- The profile's name under the title is the profile menu, as the HIG places a document menu.
- A toggle in the toolbar fills when on, and says its state to VoiceOver.
- Search is `⌘F`, the system's Edit › Find › Find…: the Edit menu keeps the system's text editing
  group (`TextEditingCommands`: Find, Spelling and Grammar, Substitutions, Transformations, Speech),
  and Find… reaches the page's search field through the responder chain when no text view takes it.
  Esc clears the search and leaves the field.

## Typography

System fonts and semantic text styles. Code and logs use `Typography.code` and `codeSmall`.

## Color

- Semantic system colors and `VeerUI` tokens only. Check light and dark.
- Never carry meaning by color alone: `StatusKind` is always icon plus text.
- Colors Veer chooses are at least 4.5:1 for text, measured from real renders where glass is involved, as it lightens what it
  is tinted with. Green behind a label or check is `accentFill` with `onAccent`; green as text or a
  glyph on the page is `veerAccent`. They differ in dark, as no one green does both. Green text on Liquid Glass (a toast's Retry or Undo) is `accentOnGlass`: the glass lightens `veerAccent` to 3.9:1 in light.
- Green is for small areas: primary actions, the node in use, written state. System controls such
  as segmented pickers keep the system's own colors.

## Materials

- Glass belongs to controls and navigation. Content panels (`panel()`) stay solid. The Agent panel is
  the one large glass surface: a helper that floats beside the page, like the toolbar's groups. It
  stays a floating panel on every system, whatever the system's own sidebars do. Nothing inside it
  has glass of its own except the composer: messages, cards and suggestions keep their solid or
  semantic fills.
- The panel's glass is the one base under its header, conversation and composer: from macOS 26 the
  conversation draws no color of its own there. The header (with a suggestion, when one shows) and the
  composer are the panel's two bars, each on glass of its own.
- macOS draws a separator line across a bar's full width, whatever the scroll edge style, unless glass
  reaches close to the bar's edges: under a plain header, under a suggestion card on its own, at a bar
  with something drawn past its bounds, and where the composer stops well short of the sides (12 pt
  margins are close enough; 24 pt, or a 760 pt reading width in a wide window, are not). Measured, not
  documented; `scrollEdgeEffectHidden` does not remove it. So the panel's bars are glass edge to edge,
  the button back to the newest turn floats over the conversation rather than in the composer's bar,
  and the Agent page, whose composer stops at the reading width, keeps a plain inset over a fade of the
  page's own color, which is its background, so the fade has no edge.
- The composer's buttons are system buttons: its option controls (execution mode, model, files, web
  search) and Stop are `secondaryAction()` circles, Send is `primaryAction()`, and web search is a
  `Toggle` in the button style, which shows its own on state and reads as a switch to VoiceOver. On,
  it fills with `accentFill`, as the toolbar's toggles do, not the system accent (blue by default). Only
  full access colors its symbol (warning); each mode has its own symbol as well (2026-11-22).
- The composer is its own regular glass shape, in the panel and on the Agent page, covering the field,
  its controls and padding. In the panel from macOS 26 it sits in a bottom `safeAreaBar` of the
  conversation, which scrolls on beneath it with the system's soft bottom edge, so text passing behind
  it is blurred, never drawn sharp under the placeholder or the draft. Its rim and shadow are the
  system's: in an active window a 1-pixel rim along the top edge and a shadow that falls only
  downward (about 15 pt), none above. A standalone app with one glass shape and no Veer code draws
  the same, and the API has no control over either. Veer adds no shadow of its own (decided
  2026-11-17, after comparing regular, clear, and regular with an all-round app shadow).
- In an active window regular glass shows sharp content behind it as readable ghost text, and the
  API has no blur control. In the panel the conversation's lines and cards therefore soften as they
  go under the composer, blurred and faded in proportion to how much of each is there
  (`SoftenedUnderComposer`). This touches the content only, never the glass, its bar or the system's
  edge, and leaves everything above the composer as it is. Nothing of Veer's is drawn on or behind the glass
  (no fill, gradient or opacity), so it follows the window's state, the appearance, Reduce
  Transparency, Increase Contrast and the system's Liquid Glass setting. Before macOS 26 it is the
  regular material in a safe-area inset, over a fade of the page's color. Its look follows the
  window's state, as all Liquid Glass does: a soft shadow and a firmer rim while Veer is the active
  app, flatter with no shadow when it is not. The API has no control over this, and the panel keeps
  the system's behaviour rather than imitating either state (decided 2026-11-17).
- Page code uses `primaryAction()`, `secondaryAction()` and `floatingPanel()`, which fall back to
  standard styles on macOS 14 and 15. It does not call `glassEffect`.

## Motion

`Motion.quick` and `Motion.standard`, or a documented spring. With Reduce Motion on, only fade.
Every curve is a `Motion` token (`quick`, `standard`, `panel`, `toolbar`, `ripple`, `step`); the
`no_literal_animation` lint rule keeps curves out of page code. What moves, resizes or scrolls uses
`Motion.unlessReduced(_:_:)`, which switches at once under Reduce Motion: the undo toasts appear
without rising, the conversation jumps to its newest turn, and the onboarding step mark
changes width at once (2026-11-22).
`CoreStateRing` around the Overview's start button turns once in 1.1 s while the core starts, and its
ripple takes 0.6 s: state feedback, not a transition, with a steady ring and no ripple under Reduce Motion.

## Components and interaction

- The Overview's big start button is the page's primary action (prominent) while the core is
  stopped or has failed; while it runs, Stop is a secondary action, as the toolbar's is, since it cuts
  every connection (2026-11-22).
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
| App Routing's rule detail sits below the list, and opens in a sheet ("Details…") when the window is too short for both | An inspector beside the list would take the width the exit menus and the Agent panel need; the list keeps at least 150 pt | SPEC 5.3.1, `AppRoutingView` |
| The window has no toolbar at all in full screen | AppKit moves a toolbar to a window of its own in front of the content, which covers the floating controls, and entering full screen shows it again if it is hidden | SPEC 5, `EmptyWindowToolbar` |
| The page title and profile menu sit on one glass capsule in the top row | Veer draws its title itself, over the window rather than in the system toolbar it leaves empty, so the system gives it no backing. Text scrolling under the row showed through the title, and the soft scroll edge (`scrollEdgeEffectStyle(.soft)`) removes only about half its contrast and has no strength to set. A full-width fade in the page background hid that text but also covered the colour of everything passing under the row, and a variable-blur shader cost about 125–170 MB more memory. The capsule is the same regular glass and 40 pt height as the toolbar's capsules, so the row reads as one set of controls. Bold text passing right behind it still shows faintly through the glass, and text in the row outside the capsules has only the soft edge | SPEC 5, `MainView.pageTitle` |
| Proxies' add button shares a glass group with the view controls | A group of its own would make four, and the HIG asks for at most three | SPEC 5, `ProxiesView` |
| Own glass switch instead of a segmented picker in the top row | Outside a real toolbar, which Veer leaves empty, the system's picker draws its own track instead of glass. The selection is a neutral shape, so it does not use the system accent | SPEC 5, `GlassSwitch` |
| Back button floats in the top row instead of `NavigationStack` | A stack's back button belongs to the system toolbar, which Veer leaves empty | SPEC 5, `MainView` |
| "Later" instead of "Cancel" in the TUN helper alert | It puts the install off rather than calling anything off, and Esc still works. The wording is the product owner's | SPEC 4.1, `HelperPrompt` |
| Sidebar selection stays in the accent color when the focus moves | Pages put the cursor in their own field, and the system's dimming then flashes between two looks on every click. The product owner asked for one look | SPEC 5, `selectionHighlight` |
| Own search field instead of `.searchable` | Several `.searchable` pages crash `NSToolbar` with a duplicate identifier on page switch (1.0.3 crash) | SPEC 5, `ToolbarSearchField` |
| Sidebar hides and shows by moving the native split view's divider, not through `NavigationSplitView`'s own collapse | Its collapse reused a stale page image, and reversing it mid-way in an 860-wide window grew the window to 1040. SwiftUI has no control of the divider, so `SidebarAnimator` drives the split view item it already has; with Reduce Motion it switches at once. While it moves, the page is told so as for the Agent panel (`PanelMotion` through `SidebarMotion`), so responsive arrangements blend instead of swapping between two frames at a breakpoint | `SidebarAnimator`, `MainView`, `SidebarMotion` |
| Agent panel and page share one custom SwiftUI layout with an animatable reveal value, instead of a split view | SwiftUI's inspector could crash on rapid reversal; an AppKit-driven divider and a window that grows were each tried and felt wrong (per-frame window growth hitched on nearly every frame; an instant resize jumped). One animated value drives the page's width, as Codex for macOS does, and a spring reverses smoothly mid-motion. The panel is pushed in from past the window's trailing edge as one piece at its full width, its leading edge on the page's trailing edge at every frame (revealing a panel resting in place read as a wipe, not a panel arriving). It is laid out once where it rests and carried by a transform on the same animated value: placed by the layout at every frame, a long conversation's views were each given a new position, at about twice the dropped frames. The spring stays out of the page, which lays itself out from its real width at every frame: carried into it, shapes interpolated on their own and drifted from their text. The page and panel ignore the pointer during motion, so a click cannot pass through the page into a still-covered panel control. Nothing structural changes during the motion: the panel is built ahead of time and kept beneath the page (except on the Agent page), and switching the pointer off and choosing each grid's and row's arrangement happen in the turn before the motion starts, input and focus after it ends; done in its first frame they froze it for up to 200 ms and it resumed most of the way open. Responsive arrangements change continuously with the page's width (`ArrangementBlend`): Overview cards, group headers and small grids go from one arrangement to the other frame by frame, across first and then between rows. Held at the narrow end's arrangement and switched at rest, as first tried, they jumped before an open and after a close. Only the large lazy node grids, a group's nodes on Proxies and a region's nodes on the map, still hold their column count through the motion (`SteadyGrid`). The panel draws above the page while it is open or moving (`zIndex`, switched once before and once after a motion): beneath the opaque page, its Liquid Glass shadow was cut off at the page edge and read as a vertical line left of the panel. A closed panel stays beneath, or its shadow would show at the window's trailing edge. Reduce Motion switches at once | PanelRevealStack, MainView |
| Plain Agent column instead of `.inspector` | `NSSplitViewController` throws if the inspector changes mid-animation (crash on 2026-10-30) | `AgentPanelColumn` |
| Veer green tint instead of the system accent color | Brand color, used only on small areas. Custom accent colors are out of scope for v1 | `Color.veerAccent` |
| Fixed chart palette | Categorical colors need stable, color-blind-checked pairs that the system colors do not give. Every chart has a legend with exact counts | `ChartPalette` |
| `.strings` instead of String Catalog | Chosen before Xcode was installed; the existing localization and checks still use it, and a migration is not scheduled | SPEC 9 |
| The Agent window's title is a menu in its toolbar, with the window title hidden | `toolbarTitleMenu` shows no menu on a Mac window that is not a document's. The menu lists recent conversations, as the panel's header does; the window keeps its title for the Window menu and VoiceOver | `AgentWindow` |
| The Agent window's top edge is the system toolbar's own (a band and a separator), not the main window's soft edge | Hiding the toolbar's background to match lost the edge effect, and a bar of Veer's under it pushed the toolbar's items into the overflow menu. Seen only in inactive windows so far | `AgentWindow` |
| In the Agent window the composer spans the window's width while turns stay at the reading width | A composer bar narrower than its window leaves the bar's sides bare, and the system draws its separator across the window | `ConversationView` |
| Edit → Undo in the Agent window does not reach routing changes | They are on the main window's undo manager, and a SwiftUI window's own cannot be swapped for it. The window's toolbar Undo, the turn's Undo and `/undo` take them back; the main window's ⌘Z still does | `AgentWindow`, `ReversibleChanges` |
| Carbon `RegisterEventHotKey` for global shortcuts | The only system API for them without a third-party library. Unbound by default | SPEC 8, `HotKeys` |

## Acceptance

Major UI changes are reviewed from real rendered output. Reading source alone cannot establish
visual compliance, and a screenshot cannot establish keyboard or VoiceOver behavior.
