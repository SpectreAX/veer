import Foundation

/// Runs slow work strictly one piece after another, in the order it was added.
@MainActor public final class SerialWork {
    public init() {}

    private var last: Task<Void, Never>?

    public func add(_ work: @escaping @MainActor () async -> Void) {
        let previous = last
        last = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Returns once everything added so far has finished.
    public func finish() async {
        await last?.value
    }
}
