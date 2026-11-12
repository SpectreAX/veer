import Foundation

/// Main-actor request identity and a single FIFO for *all* work that can change the core or its
/// files. Invalidation is synchronous; draining is deliberately not cancellation: a detached
/// core start or an in-flight file write must finish before stop, and stop before the next start.
@MainActor
final class CoreLifecycle {
    struct Token: Equatable, Sendable {
        let generation: UUID
        let profileID: UUID
    }

    private(set) var current: Token?
    private var tail: Task<Void, Never>?
    private var lastSubmission = UUID()

    @discardableResult
    func begin(profileID: UUID) -> Token {
        let token = Token(generation: UUID(), profileID: profileID)
        current = token
        return token
    }

    func invalidate() { current = nil }
    func contains(_ token: Token) -> Bool { current == token }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        lastSubmission = UUID()
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    func settle() async {
        while let task = tail {
            let submission = lastSubmission
            await task.value
            if submission == lastSubmission { return }
        }
    }
}
