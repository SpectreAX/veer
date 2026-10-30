---
paths:
  - "**/*.swift"
---

# AppKit interop

Use AppKit for native capabilities SwiftUI does not expose well: advanced window management, the
responder chain, or accessibility it cannot express.

- State the limitation being solved in a comment.
- Isolate the bridge, and handle its lifecycle and ownership correctly.
- Respect the responder chain and preserve accessibility.
- Avoid unnecessary `NSHostingView` nesting.
- Do not replace a standard SwiftUI control with AppKit without a reason.
- Check API availability against the deployment target.
