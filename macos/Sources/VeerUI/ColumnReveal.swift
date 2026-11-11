import AppKit
import Observation

/// A column that slides in over a page and then takes its room. The slide is stepped frame by frame
/// (`progress`) while the page keeps its width, so nothing in the page lays out again each frame; on
/// real data that cost 30 to 70 ms a frame, and grids and tables reflowed in jumps as the width passed
/// each of their thresholds. The page changes width once (`reservesSpace`): after the column has slid
/// in, or, as it slides out, at the start, underneath it.
@Observable public final class ColumnReveal {
    public private(set) var progress: CGFloat
    /// Whether the page should leave room for the column.
    public private(set) var reservesSpace: Bool
    public var isAnimating: Bool { animation != nil }
    @ObservationIgnored private var animation: DividerAnimation?

    public init(visible: Bool = false) {
        progress = visible ? 1 : 0
        reservesSpace = visible
    }

    /// Moves to shown or hidden, from wherever it is; at once with Reduce Motion.
    public func animate(to visible: Bool, reduceMotion: Bool) {
        stop()
        let start = progress, end: CGFloat = visible ? 1 : 0
        guard !reduceMotion, start != end else { return settle(visible) }
        // The page takes back the room before the column slides away, and gives it up only after.
        reservesSpace = false
        let driver = DividerAnimation { [weak self] value in
            self?.progress = start + (end - start) * value
        } completion: { [weak self] in
            self?.animation = nil
            self?.settle(visible)
        }
        animation = driver
        driver.start()
    }

    /// Shown or hidden at once, as when the page that has no column comes or goes.
    public func jump(to visible: Bool) {
        stop()
        settle(visible)
    }

    private func settle(_ visible: Bool) {
        progress = visible ? 1 : 0
        reservesSpace = visible
    }

    private func stop() {
        animation?.delegate = nil
        animation?.stop()
        animation = nil
    }
}
