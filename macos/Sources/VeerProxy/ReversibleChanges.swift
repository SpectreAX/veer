import Foundation

/// Changes that Edit → Undo and Redo can take back, on the window's undo manager. Each undo registers
/// its opposite as a redo, as the manager expects. Each change has a target of its own, the one thing
/// the manager can remove by, so that a change undone some other way leaves no menu item behind.
@MainActor public final class ReversibleChanges {
    public init() {}

    public weak var manager: UndoManager? {
        didSet {
            if manager !== oldValue { entries = Stacks() }
        }
    }

    private final class Target {}

    private struct Entry {
        let id: UUID
        let group: UUID
        let name: String
    }

    private struct Stacks {
        var undo: [Entry] = []
        var redo: [Entry] = []
    }

    private var entries = Stacks()
    /// The manager doesn't keep its targets.
    private var targets: [UUID: Target] = [:]

    /// Records that change `id`, in `group`, was made. Undoing it calls `change` with `undoTo`, and its
    /// opposite when redoing. `change` returns false when there is no way back from that, which ends the chain.
    public func made(_ name: String, id: UUID, group: UUID, undoTo state: Bool, change: @escaping @MainActor (Bool) -> Bool) {
        guard let manager else { return }
        let entry = Entry(id: id, group: group, name: name)
        let target = targets[id] ?? Target()
        targets[id] = target
        // A group of its own, closed now: forgetting a change still in the group the manager opens by
        // itself would leave that group behind, empty, as a Cmd-Z that does nothing.
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.run(entry, to: state, change: change)
            }
        }
        manager.setActionName(name)
        manager.endUndoGrouping()
        if manager.isUndoing {
            entries.redo.append(entry)
        } else {
            entries.undo.append(entry)
            if !manager.isRedoing { entries.redo.removeAll() }
        }
    }

    private func run(_ entry: Entry, to state: Bool, change: @escaping @MainActor (Bool) -> Bool) {
        guard let manager else { return }
        if manager.isUndoing { entries.undo.removeLast() } else { entries.redo.removeLast() }
        if change(state) {
            made(entry.name, id: entry.id, group: entry.group, undoTo: !state, change: change)
        } else if !entries.undo.contains(where: { $0.id == entry.id }), !entries.redo.contains(where: { $0.id == entry.id }) {
            targets[entry.id] = nil
        }
    }

    /// Undoes change `id` if it is next, which the menu then shows as Redo, as if it were chosen there.
    /// False if something else is next, such as typing, or another conversation's change.
    public func undoIfNext(_ id: UUID) -> Bool {
        guard let manager, let next = entries.undo.last, next.id == id, manager.canUndo,
              manager.undoActionName == next.name else { return false }
        manager.undo()
        return true
    }

    public func redoIfNext(_ id: UUID) -> Bool {
        guard let manager, let next = entries.redo.last, next.id == id, manager.canRedo,
              manager.redoActionName == next.name else { return false }
        manager.redo()
        return true
    }

    /// For a change undone some other way, or that has gone.
    public func forget(_ id: UUID) {
        if let target = targets.removeValue(forKey: id) { manager?.removeAllActions(withTarget: target) }
        entries.undo.removeAll { $0.id == id }
        entries.redo.removeAll { $0.id == id }
    }

    public func forget(group: UUID) {
        let ids = Set((entries.undo + entries.redo).filter { $0.group == group }.map(\.id))
        for id in ids { forget(id) }
    }
}
