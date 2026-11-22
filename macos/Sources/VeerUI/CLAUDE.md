# VeerUI

Tokens and shared components.

- UI only: no business logic, no services, no file or network access. From `VeerCore` it takes value
  types such as `Region` and `Target.Kind`, to decide how they look.
- macOS 26 APIs stay here, behind `#available`, with a fallback that works on macOS 14.
- A new custom control needs a row in `Design/COMPONENTS.md`, saying why the native one is not enough.
- Green behind a label or check is `accentFill` with `onAccent`. Green as text or a glyph is `veerAccent`.
  They differ in dark, as no one green does both. Green text on Liquid Glass is `accentOnGlass`, as glass lightens
  `veerAccent` below 4.5:1 in light.
