# Design tokens

Defined in [Sources/VeerUI/Tokens.swift](../Sources/VeerUI/Tokens.swift), which is the source of
truth. Prefer a system semantic value; use a token when Veer needs its own.

## Spacing

`Spacing`, on a 4-point grid: `xxs` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24, `xxl` 32, `xxxl` 48.
Do not force native controls into matching sizes.

## Radius

`Radius`: `tiny` 4 (keycaps only), `small` 6, `medium` 10, `large` 16.

## Layout

`Metrics`: `readingWidth` 760, `sidebarWidth` 240, `inspectorWidth` 360, `minWindow` 860 × 560,
`defaultWindow` 1080 × 720, `compactBreakpoint` 1100.

## Motion

`Motion.quick` (ease out, 0.15 s) and `Motion.standard` (ease in-out, 0.22 s). With Reduce Motion on,
only fade.

## Color

| Token | Use |
|---|---|
| `veerAccent` | Small areas: primary actions, the node in use, written state |
| `accentFill` | Behind a label: primary actions and toolbar toggles that are on. Darker than `veerAccent` in dark |
| `onAccent` | A label or glyph on `accentFill` |
| `selectionFill` | The selected row of a sidebar or list, with `onAccent` over it |
| `userBubble` | The user's message bubble |
| `statusSuccess`, `statusWarning`, `statusFailure`, `statusInfo` | Status, always with an icon and text through `StatusKind`. Warning and failure are darker than the system's in light, as small text on white |
| `surface`, `surfaceRaised`, `surfaceSunken` | Window, raised and recessed backgrounds |
| `separatorLine` | Separators |
| `codeBackground` | Code and diffs |
| `diffAdded`, `diffRemoved` | Diff lines |
| `subtleFill` | Quiet fill for secondary text |
| `ChartPalette` | Categorical chart colors in fixed order. A seventh category folds into `other` |

Use `Color.primary` and `Color.secondary` for text. Raw colors belong only in `VeerUI`; SwiftLint
enforces this.

## Typography

Semantic text styles: `.largeTitle`, `.title`, `.title2`, `.title3`, `.headline`, `.body`, `.callout`,
`.subheadline`, `.footnote`, `.caption`. Code and logs use `Typography.code` and `Typography.codeSmall`.

A fixed size needs a product reason in a comment. SwiftLint flags `.system(size:)`.

## Symbols

Prefer SF Symbols, choose them for meaning, and label icon-only controls. Status symbols come from
`StatusKind.symbol`.
