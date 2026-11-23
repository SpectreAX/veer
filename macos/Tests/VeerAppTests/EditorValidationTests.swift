import Testing
@testable import VeerApp

/// Editors say why their input can't be saved, and their Save or Add buttons follow the same rules.
@MainActor struct EditorValidationTests {
    @Test func aDomainExceptionExplainsWhatItCannotTake() {
        #expect(DomainRouteSheet.problem("") == nil)
        #expect(DomainRouteSheet.problem("   ") == nil)
        #expect(DomainRouteSheet.problem("youtube.com") == nil)
        #expect(DomainRouteSheet.problem(" .youtube.com. ") == nil)
        for pasted in ["https://www.youtube.com/watch", "youtube.com/watch", "you tube.com", "a,b.com", "*.youtube.com", "what?"] {
            #expect(DomainRouteSheet.problem(pasted) != nil, "\(pasted)")
        }
    }

    @Test func aGroupNameBlocksSavingOnlyWhenTheNoteSaysItMayNot() {
        let none: (String) -> Bool = { _ in false }
        #expect(GroupEditorSheet.nameIssue("", taken: none)?.blocksSaving == true)
        #expect(GroupEditorSheet.nameIssue("a,b", taken: none)?.blocksSaving == true)
        #expect(GroupEditorSheet.nameIssue(String(repeating: "a", count: 64), taken: none) == nil)
        // Over 64 characters: the note said so before, and Save stayed enabled.
        #expect(GroupEditorSheet.nameIssue(String(repeating: "a", count: 65), taken: none)?.blocksSaving == true)
        // A name in use is a note; saving numbers it.
        let taken = GroupEditorSheet.nameIssue("Netflix", taken: { $0 == "Netflix" })
        #expect(taken != nil && taken?.blocksSaving == false)
        #expect(GroupEditorSheet.nameIssue("  Netflix  ", taken: { $0 == "Netflix" })?.blocksSaving == false)
    }
}
