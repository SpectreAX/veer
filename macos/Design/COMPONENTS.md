# Components

Use the native control first, then a `VeerUI` component, then a new one. Shared components are in
[Sources/VeerUI/Components.swift](../Sources/VeerUI/Components.swift).

## Native controls

| Need | Use |
|---|---|
| Action | `Button` with a native style, or the action styles below |
| Text input | `TextField`, `TextEditor` |
| Selection | `Picker`, `List`, `Table` |
| Navigation | `NavigationSplitView` |
| Menus | `Menu`, `CommandMenu`, `CommandGroup`, context menus |
| Dialogs | `sheet`, `alert`, `confirmationDialog` |

## Veer styles

| Style | Use |
|---|---|
| `primaryAction()` | The one primary action on a page. `.glassProminent` on macOS 26, `.borderedProminent` before |
| `secondaryAction()` | Secondary actions beside content. `.glass` on macOS 26, `.bordered` before |
| `floatingPanel()` | Panels floating over the window, such as onboarding |
| `panel()` | Content panels: solid, no glass |
| `neutralControl()` | A control that should not take the accent color |
| `.labelStyle(.iconTarget)` | A borderless icon-only button with a `Metrics.iconTarget` (28 pt) click target rather than its glyph. The frame is inside the label, because a borderless button on macOS is an AppKit button sized to its label; a frame around the button does not reach it (measured 2026-11-22). Agent panel header |
| `SoftenedUnderComposer` | Softens a conversation line or card in proportion to how much of it is under the composer's glass, which in an active window otherwise shows sharp text behind it; the glass API has no blur control. It follows layout, as a draw-time `visualEffect` on every line kept a layer each (about 47 MB), and goes on each line directly, as a container wrapping each child slowed the panel's motion. |
| `glassSurface(in:)` | A glass surface with the older-system fallback. The Agent panel (`AgentPanelColumn`) is one: the whole column on one regular glass shape, clipped to it underneath so the system keeps its own edge, with a separator-colored edge added only under Increase Contrast |

## Veer components

| Component | Use |
|---|---|
| `StatusBadge` | Status as an icon and text |
| `Tag` | A small label |
| `Chip` | Compact pill for a suggested instruction or a choice in a turn (`Chip(text:symbol:action:)`). The composer's option controls, which used `ToggleChip` and `PillButtonStyle`, are system buttons since 2026-11-22 (`composerOption()`: `secondaryAction()` in a circle; web search a `Toggle` in the button style). |
| `StateView` | Empty, loading and error states |
| `ExitLabel` | Exit node and country |
| `SegmentedControl` | Standard segmented picker in the system's colors, for symbols or text |
| `GlassSwitch` | A switch in its own group of glass, for the window's top row, in symbols or text. The system's segmented picker draws its own track outside a real toolbar. Native alternative: `SegmentedControl`, anywhere else. Segments are buttons: keyboard and VoiceOver through them, with an `.isSelected` trait |
| `GlassGroup`, `glassSurface` | Glass on macOS 26, the regular material before it. `glassSurface(in:id:namespace:)` inside a `GlassGroup` fades a shape's glass in and out in place as it comes and goes, as the toolbar's groups do |
| `ScrollEdge`, `softScrollEdge`, `scrollEdgeBar` | Not a control: macOS 26 bars over scrolling content (`safeAreaBar`) and the system's soft scroll edge, with `ScrollEdge.available` for layouts that differ around such a bar. Before macOS 26, no edge effect and an ordinary inset. Pages use these instead of the macOS 26 APIs, which stay in `VeerUI` (lint rule `no_macos26_api_outside_veerui`) |
| `ToolbarToggle` | A switch in a toolbar group: a button that fills when on, since the groups' controls are round icon buttons. Keyboard and VoiceOver as a button with the toggle trait and its state as the value. Light and dark through `accentFill` and `onAccent`; same on macOS 14 |
| `ProfileTile`, `ToolRow` | A row of plain buttons with secondary actions beside them, on `ProxiesView` and `ToolsView`. Plain buttons, so keyboard and VoiceOver work as for any button |
| `CoreStateRing` | A ring and ripple around the Overview's start button, for what the core is doing. Decorative: hidden from VoiceOver, which hears the new state as an announcement. Same in light and dark and on macOS 14; steady with Reduce Motion |
| `selectionHighlight` | A selected row in the sidebar and conversation list, in `selectionFill` whatever has the focus, since pages move the focus to their own fields. Dimmed by the system when the window is in the background |
| `CompletionList` | The Agent composer's `@` exit and `/` command completion, floating above it as a menu does: solid `surfaceRaised` with a separator edge and no shadow (nothing in the Agent panel but the composer has glass, as regular glass shows the conversation sharp behind it), the highlighted row in `selectionFill` with `onAccent`, at most 340 pt and never wider than the composer (2026-11-22: a fixed 340 pt ran past a 320 pt panel and cut off the kind tags). Native alternatives fall short: `NSTextView.complete(_:)` lists bare words with no region or kind and takes the keyboard into its own window; SwiftUI's `textInputSuggestions` is for a `TextField` on macOS 15 and later, not this text view. Keyboard: the text view keeps focus; Up and Down move the highlight, Return or Tab picks, Esc closes, typing filters. The pointer highlights on hover and picks on click. VoiceOver: each row is a button, the highlighted one with the selected trait. Light and dark through `surfaceRaised`, `separatorLine` and the system selection color; the same on macOS 14 |
| `AttachmentChip` | A file or image going with an Agent instruction, removable in the composer. A row of name, state and remove button that no system control offers. Keyboard and VoiceOver through its plain remove button; its label says what was hidden or cut. Same in light and dark through `subtleFill`, and on macOS 14 |
| `ColumnFit` | Not a control: which table columns to hide so that the rest fit, for tables that narrow beside a panel |
| `PanelRevealStack` | Page and Agent panel in one `Layout` whose animatable `reveal` drives both: the page gets each real width, and the panel, at its full width, is pushed in from past the trailing edge by a transform on the same value, its leading edge on the page's trailing edge. The panel draws above the page while open or moving, so its glass shadow falls on the page. No native split view offers a trailing panel that animates with the page on one curve without the inspector's crash. |
| `TopRowBar` | Marks the window's own top row as a bar over the page with `scrollEdgeBar` (macOS 26's `safeAreaBar`), so scroll views meeting it get the system's soft scroll edge (`scrollEdgeEffectStyle(.soft, for: .top)`). The row is drawn over the window, not in a system toolbar, and the system gives no edge effect to a bar it does not know about, or to an entirely clear one. The page title and profile menu sit on their own glass capsule (`MainView.pageTitle`, 40 pt like `ToolbarCapsule`), because the soft edge leaves text behind the title readable and has no strength to set. Before macOS 26 it does nothing and the page stays clipped below the row. |
| `ArrangementBlend`, `BlendedGrid`, `BlendedHeader` | Carry a set of views from one responsive arrangement to another as a function of the width they are laid out in, while the Agent panel or the sidebar moves (the sidebar's motion reaches the page as the same `PanelMotion`, through `SidebarMotion`): across first, each in its row, then between rows, with no overlap, no animation value of their own and no switch before or after the motion. SwiftUI's `ViewThatFits`, adaptive grids and `AnyLayout` switch arrangement in one frame. `BlendedGrid` is not lazy and is for a handful of items. Known limit (2026-11-20): a grid going from 2 to 3 columns moves an item across a row whose order reverses, so it passes under its neighbour for part of the motion (node map regions); the narrow end has no free space for another path. |
| `SuggestionCards` (stack) | Several suggestions as one card with the others' edges behind it and a count, expanding to the full list, as Notification Center stacks notifications. A plain list of five cards took most of the Overview and all of the Agent panel's conversation. |
| `MenuBarMark` | Veer's mark drawn as a template image for the menu bar. An SF Symbol is not the brand, and the app icon scaled down carries its body and shadow. |
| Node map (`WorldMap`, `MapSurface`) | A choropleth of Natural Earth outlines drawn in one `Canvas`, with an animatable viewport for going in on a region, panning and pinching. MapKit shows streets and labels this page has no use for, and cannot fill countries by node count without its own overlays; one canvas also replaces the badge views, one per region, that covered each other at 80 regions. |
| `SteadyGrid` | `LazyVGrid` with adaptive columns whose count holds while the Agent panel moves: the count that fits at the motion's narrower end, chosen before it starts, and adaptive again at rest. An adaptive grid alone re-arranges every item two or three times in one motion. |
| `SteadyColumns`, `EqualColumnsRow`, `panelSlice` | The Proxies grid as one `LazyVStack` of headers and rows of node tiles, each item a part of its group's panel (`panelSlice`: top, middle, bottom or whole, the same fill, corners and edge as `panel()`). `SteadyColumns` reads one column count from the list's width and holds it while a panel moves, as `SteadyGrid` does; `EqualColumnsRow` lays one row out in equal columns. A `LazyVGrid` per section measured every tile to know its height, so expanding every group measured every tile on the page, and lazy stacks nested in a section are not lazy. Collapse and expand change the layout at once: a lazy list cannot move sections in from outside the window without them crossing. |
| `LazyPullDown` | A borderless pull-down (`NSPopUpButton`, `pullsDown`), a line of text, whose items are made only as it opens (`NSMenuDelegate.menuNeedsUpdate`). A SwiftUI `Menu` makes all its items on every update of its view; the Proxies page and Overview had one per group with a few hundred members each, thousands of items rebuilt with every change. Used for the groups' node-in-use menus (`GroupQuickSwitchMenu`, items from `NodeMenuBuckets`); the menu bar keeps a SwiftUI menu over the same buckets. Keyboard and VoiceOver as the system pop-up button: a label for the group, the node as its value, the checkmark as the item state. |
| `SteadyChoice` | `ViewThatFits` for two arrangements whose choice holds while the Agent panel moves, given the width the wider one needs. At rest it is `ViewThatFits` itself; during the motion the wider one reports an ideal width that always or never fits, so the views stay and only the choice is fixed. |
| `ConnectionsTable` | Native NSTableView: SwiftUI Table hosted-cell measurement made each live split-divider step expensive; retains native multi-selection, context actions, keyboard commands and stable row IDs Its columns never change with the page's width; one the page's edge has passed fades (header and cells, `FadingHeaderCell`) rather than being hidden, which moved every other column at once. The requests page uses it too, in its ended form (`closed:`), in place of a SwiftUI `Table` that was rebuilt whenever its columns changed. |
| `AgentWindow`, `AgentWindowBridge` | Not a custom control: the Agent's own window, a standard `Window` scene showing the panel's `AgentConversation` from the same store, with system toolbar items (a title menu of recent conversations, Undo, New Conversation, Dock to Main Window). The bridge is AppKit for what the scene lacks on macOS 14: first placement on the main window's screen (`defaultWindowPlacement` needs macOS 15), the saved frame clamped back on screen after a display change (`AgentWindowPlacement`), Always on Top (`NSWindow.level`), no state restoration and no tabbing. The title is a toolbar `Menu` because `toolbarTitleMenu` shows nothing on a non-document Mac window |
| `AppIcon` | An app's or tool's own icon, as Finder shows it, from `NSWorkspace.icon(forFile:)` (SwiftUI has no source for it), cached by path. Decorative: hidden from VoiceOver, which reads the name beside it. Same in light and dark, and on macOS 14 |
| `KeyCap`, `ShortcutHint` | Keyboard shortcut display |
| `ChoiceRow` | A row in a choice list |

Toolbar pieces are in `VeerApp`: `ToolbarCapsule`, `ToolbarToggle`, `ToolbarSearchField` and `pageToolbar`.

## Adding a custom component

Add a row above and state:

- Why native controls are not enough
- Keyboard behavior
- Accessibility behavior
- Appearance in light and dark
- Behavior on macOS 14 as well as macOS 26
