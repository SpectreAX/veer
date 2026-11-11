import AppKit
import Observation

/// How much of a column beside a split view shows, from 0 to 1, stepped frame by frame. A SwiftUI
/// animation would give the split view its final width at once and slide only the drawing, so the
/// page would jump to its new layout while the column was still moving in. Each step here is a real
/// layout pass, so the page narrows and widens with the column.
@Observable public final class ColumnReveal {
    public private(set) var progress: CGFloat
    public var isAnimating: Bool { animation != nil }
    @ObservationIgnored private var animation: DividerAnimation?

    public init(visible: Bool = false) { progress = visible ? 1 : 0 }

    /// Moves to shown or hidden, from wherever it is; at once with Reduce Motion.
    public func animate(to visible: Bool, reduceMotion: Bool) {
        stop()
        let start = progress, end: CGFloat = visible ? 1 : 0
        guard !reduceMotion, start != end else { progress = end; return }
        let driver = DividerAnimation { [weak self] value in
            self?.progress = start + (end - start) * value
        } completion: { [weak self] in
            self?.progress = end
            self?.animation = nil
        }
        animation = driver
        driver.start()
    }

    /// Shown or hidden at once, as when the page that has no column comes or goes.
    public func jump(to visible: Bool) {
        stop()
        progress = visible ? 1 : 0
    }

    private func stop() {
        animation?.delegate = nil
        animation?.stop()
        animation = nil
    }
}
