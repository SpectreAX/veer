import Foundation
import Testing
@testable import VeerProxy

@MainActor struct ReversibleChangesTests {
    /// Changes that are on or off, using the native undo manager.
    @MainActor private final class Fixture {
        let manager = UndoManager()
        let changes = ReversibleChanges()
        let group = UUID()
        var state: [UUID: Bool] = [:]
        var refuses = false

        init(groupsByEvent: Bool = false) {
            manager.groupsByEvent = groupsByEvent
            changes.manager = manager
        }

        @discardableResult func apply(_ id: UUID = UUID(), group: UUID? = nil) -> UUID {
            state[id] = true
            changes.made("Change", id: id, group: group ?? self.group, undoTo: false) { [self] on in
                guard !refuses else { return false }
                state[id] = on
                return true
            }
            return id
        }

        func typeSomething() {
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: self) { _ in }
            manager.setActionName("Typing")
            manager.endUndoGrouping()
        }
    }

    @Test func undoAndRedoGoBackAndForth() {
        let fixture = Fixture()
        let id = fixture.apply()
        #expect(fixture.manager.undoActionName == "Change")
        fixture.manager.undo()
        #expect(fixture.state[id] == false)
        #expect(fixture.manager.redoActionName == "Change")
        fixture.manager.redo()
        #expect(fixture.state[id] == true)
        fixture.manager.undo()
        #expect(fixture.state[id] == false)
    }

    /// A button undoing the next change: the menu moves on to Redo, not to an Undo that re-applies it.
    @Test func aButtonMovesTheMenuOnAsTheMenuWould() {
        let fixture = Fixture()
        let id = fixture.apply()
        #expect(fixture.changes.undoIfNext(id))
        #expect(fixture.state[id] == false)
        #expect(!fixture.manager.canUndo)
        #expect(fixture.manager.canRedo)
        #expect(fixture.changes.redoIfNext(id))
        #expect(fixture.state[id] == true)
        #expect(fixture.manager.canUndo)
        #expect(!fixture.manager.canRedo)
    }

    @Test func onlyTheNextChangeCanBeTakenThatWay() {
        let fixture = Fixture()
        let first = fixture.apply()
        let second = fixture.apply()
        #expect(!fixture.changes.undoIfNext(first))
        #expect(fixture.state[first] == true)
        #expect(fixture.changes.undoIfNext(second))
        #expect(fixture.changes.undoIfNext(first))
    }

    @Test func twoChangesInOneEventHaveSeparateUndoGroups() {
        let fixture = Fixture(groupsByEvent: true)
        let first = fixture.apply()
        let second = fixture.apply()
        #expect(fixture.manager.groupsByEvent)
        #expect(fixture.changes.undoIfNext(second))
        #expect(fixture.state[second] == false)
        #expect(fixture.state[first] == true)
        #expect(fixture.changes.redoIfNext(second))
        #expect(fixture.state[second] == true)
        #expect(fixture.changes.undoIfNext(second))
        #expect(fixture.changes.undoIfNext(first))
    }

    @Test func aCardLeavesTheRestOfAnExistingGroupAlone() {
        let fixture = Fixture()
        fixture.manager.beginUndoGrouping()
        let first = fixture.apply()
        let second = fixture.apply()
        fixture.manager.endUndoGrouping()

        #expect(!fixture.changes.undoIfNext(second))
        #expect(fixture.state[first] == true)
        #expect(fixture.state[second] == true)
        // The card applies its own change and removes only its action from the native group.
        fixture.state[second] = false
        fixture.changes.forget(second)
        fixture.manager.undo()
        #expect(fixture.state[first] == false)
        #expect(fixture.state[second] == false)
        #expect(!fixture.changes.redoIfNext(first))
        fixture.manager.redo()
        #expect(fixture.state[first] == true)
        #expect(fixture.state[second] == false)
    }

    /// Cmd-Z in a text field takes the typing, and a button must not take it instead.
    @Test func typingOnTopIsLeftAlone() {
        let fixture = Fixture()
        let id = fixture.apply()
        fixture.typeSomething()
        #expect(!fixture.changes.undoIfNext(id))
        #expect(fixture.state[id] == true)
        #expect(fixture.manager.undoActionName == "Typing")
    }

    /// Undone another way: its menu item goes, and the one under it comes next, as nothing has moved.
    @Test func aForgottenChangeLeavesNoMenuItem() {
        let fixture = Fixture()
        let first = fixture.apply()
        let second = fixture.apply()
        fixture.changes.forget(second)
        #expect(fixture.manager.canUndo)
        fixture.manager.undo()
        #expect(fixture.state[first] == false)
        #expect(fixture.state[second] == true)
        #expect(!fixture.manager.canUndo)
    }

    @Test func aRefusedChangeEndsTheChain() {
        let fixture = Fixture()
        let id = fixture.apply()
        fixture.refuses = true
        fixture.manager.undo()
        #expect(fixture.state[id] == true)
        #expect(!fixture.manager.canRedo)
        #expect(!fixture.changes.redoIfNext(id))
    }

    /// Deleting one conversation takes its changes, and leaves the others'.
    @Test func forgettingAGroupLeavesTheOthers() {
        let fixture = Fixture()
        let other = UUID()
        let kept = fixture.apply(group: other)
        fixture.apply()
        fixture.changes.forget(group: fixture.group)
        #expect(fixture.manager.canUndo)
        fixture.manager.undo()
        #expect(fixture.state[kept] == false)
        #expect(!fixture.manager.canUndo)
    }

    @Test func withoutAManagerNothingHappens() {
        let fixture = Fixture()
        fixture.changes.manager = nil
        fixture.changes.made("Change", id: UUID(), group: fixture.group, undoTo: false) { _ in true }
        #expect(!fixture.manager.canUndo)
    }
}
