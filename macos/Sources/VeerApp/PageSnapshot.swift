import AppKit
import SwiftUI

/// A picture of the page as it is on screen now, to fade out over the page once it has a new layout.
/// SwiftUI has no snapshot of a live view, and AppKit's `cacheDisplay` leaves out parts of what
/// SwiftUI draws (cards came out without their fill, some not at all), so this copies the window's
/// own pixels. `CGWindowListCreateImage` is the only call that does that without asking for screen
/// recording, which a window's own content does not need; the SDK no longer declares it, so it is
/// looked up by name, and when it is gone there is no picture and the page switches at once.
@MainActor final class PageSnapshotSource {
    fileprivate weak var anchor: NSView?
    private var pending: NSImage?

    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let windowImage: WindowImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: WindowImage.self) }

    /// Draws the page now, for whoever handles the change that is about to happen.
    func capturePending(insets: NSEdgeInsets) { pending = capture(insets: insets) }

    func takePending() -> NSImage? {
        defer { pending = nil }
        return pending
    }

    /// The anchor's area less `insets` (the row of window controls above the page, and what lies
    /// over its trailing edge), or nil when it cannot be copied.
    func capture(insets: NSEdgeInsets) -> NSImage? {
        guard let anchor, let window = anchor.window, window.isVisible, let primary = NSScreen.screens.first,
              let copy = Self.windowImage else { return nil }
        var rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // AppKit measures up from the bottom of the main screen, Quartz down from its top.
        rect.origin.y = primary.frame.maxY - rect.maxY
        rect = CGRect(x: rect.minX + insets.left, y: rect.minY + insets.top,
                      width: rect.width - insets.left - insets.right, height: rect.height - insets.top - insets.bottom)
        guard rect.width > 0, rect.height > 0 else { return nil }
        // This window alone, at the screen's own resolution, without its shadow.
        let onlyThisWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = copy(rect, onlyThisWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?.takeRetainedValue() else { return nil }
        return NSImage(cgImage: image, size: rect.size)
    }
}

/// Marks the area `PageSnapshotSource` captures: place it behind the page.
struct PageSnapshotAnchor: NSViewRepresentable {
    let source: PageSnapshotSource

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        source.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { source.anchor = view }
}

/// The page's picture going: it blurs as it fades. Faded alone, the old layout's text stays sharp over
/// the new one's, and two sets of table columns over each other read as a fault.
struct PictureLeaving: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content.blur(radius: 12 * progress).opacity(1 - progress)
    }

    static var transition: AnyTransition {
        .modifier(active: PictureLeaving(progress: 1), identity: PictureLeaving(progress: 0))
    }
}
