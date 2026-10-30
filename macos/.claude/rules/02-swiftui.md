---
paths:
  - "**/*.swift"
---

# SwiftUI

- SwiftUI is the default UI framework. Prefer native containers and controls.
- Use `Button` for actions, not tap handlers on `Text` or shapes, which lose focus and VoiceOver.
- Use `Table` for structured desktop data where it fits.
- Use the project's tokens and styles instead of literal colors, spacing and glass.
- Keep state ownership clear and side effects out of `body`.
- Use stable identifiers in dynamic collections.
- Handle empty, loading, error and populated states.
- Consider window resizing in every major layout.
- Check whether the project already has an equivalent before adding an abstraction.
