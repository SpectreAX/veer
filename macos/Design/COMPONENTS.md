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
| `glassSurface(in:)` | A glass surface with the older-system fallback |

## Veer components

| Component | Use |
|---|---|
| `StatusBadge` | Status as an icon and text |
| `Tag` | A small label |
| `Chip`, `ToggleChip`, `PillButtonStyle` | Compact pills |
| `StateView` | Empty, loading and error states |
| `ExitLabel` | Exit node and country |
| `SegmentedControl` | Standard segmented picker in the system's colors, for symbols or text |
| `GlassSwitch` | A switch in its own group of glass, for the window's top row, in symbols or text. The system's segmented picker draws its own track outside a real toolbar. Native alternative: `SegmentedControl`, anywhere else. Segments are buttons: keyboard and VoiceOver through them, with an `.isSelected` trait |
| `GlassGroup`, `glassSurface` | Glass on macOS 26, the regular material before it |
| `ToolbarToggle` | A switch in a toolbar group: a button that fills when on, since the groups' controls are round icon buttons. Keyboard and VoiceOver as a button with the toggle trait and its state as the value. Light and dark through `accentFill` and `onAccent`; same on macOS 14 |
| `ProfileTile`, `ToolRow` | A row of plain buttons with secondary actions beside them, on `ProxiesView` and `ToolsView`. Plain buttons, so keyboard and VoiceOver work as for any button |
| `CoreStateRing` | A ring and ripple around the Overview's start button, for what the core is doing. Decorative: hidden from VoiceOver, which hears the new state as an announcement. Same in light and dark and on macOS 14; steady with Reduce Motion |
| `selectionHighlight` | A selected row in the sidebar and conversation list, in `selectionFill` whatever has the focus, since pages move the focus to their own fields. Dimmed by the system when the window is in the background |
| `ColumnFit` | Not a control: which table columns to hide so that the rest fit, for tables that narrow beside a panel |
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
