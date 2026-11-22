import Foundation

/// Runs slow work strictly one piece after another, in the order it was added.
@MainActor public final class SerialWork {
    public init() {}

    private var last: Task<Void, Never>?

    @discardableResult public func add<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let previous = last
        let entry = Task { @MainActor in
            await previous?.value
            return await work()
        }
        last = Task { _ = await entry.value }
        return entry
    }

    public func run<Value: Sendable>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let entry = add {
            do { return Result<Value, Error>.success(try await work()) } catch { return .failure(error) }
        }
        return try await entry.value.get()
    }

    /// Returns once everything added so far has finished.
    public func finish() async {
        await last?.value
    }
}
