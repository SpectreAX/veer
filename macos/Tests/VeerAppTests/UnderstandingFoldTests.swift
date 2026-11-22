import Foundation
import Testing
@testable import VeerApp
import VeerCore

/// Where the model's restatement of a request goes: under the meta line once the turn's changes are
/// settled, in view while they wait for a decision or when it is the only context the answer has.
@MainActor @Suite struct UnderstandingFoldTests {
    private static let steps = [Turn.Step(id: 0, title: "理解指令", state: .done)]

    private static func turn(_ outcome: Turn.Outcome, steps: [Turn.Step] = steps, understanding: String? = "把 Netflix 交给日本节点") -> Turn {
        var turn = Turn(prompt: "Netflix 走日本", mode: .local, steps: steps, outcome: outcome)
        turn.understanding = understanding
        return turn
    }

    private static func proposal(_ status: Turn.ProposalStatus) -> Turn.Outcome {
        .proposal(Turn.Proposal(plan: EditPlan(operations: []), items: [], accepted: [], baseDraft: "", candidate: "",
                                validation: ValidationResult(status: .passed, message: ""), status: status))
    }

    private static func appRouting(_ status: AppRoutingProposal.Status) -> Turn.Outcome {
        .appRouting(AppRoutingProposal(changes: [], status: status))
    }

    private static func runtime(finished: Bool) -> Turn.Outcome {
        var run = RuntimeRun(steps: [.mode("rule")])
        if finished { run.items[0].state = .done }
        return .runtime(run)
    }

    /// The model writes its caveats there, such as a direct route nobody tested: they come before Apply.
    @Test func changesWaitingForADecisionKeepItInView() {
        #expect(!Self.turn(Self.proposal(.pending)).foldsUnderstanding)
        #expect(!Self.turn(Self.appRouting(.pending)).foldsUnderstanding)
        #expect(!Self.turn(Self.runtime(finished: false)).foldsUnderstanding)
    }

    @Test func settledChangesFoldIt() {
        for status in [Turn.ProposalStatus.written, .undone, .discarded, .stale] {
            #expect(Self.turn(Self.proposal(status)).foldsUnderstanding)
        }
        for status in [AppRoutingProposal.Status.applied, .undone, .discarded, .failed] {
            #expect(Self.turn(Self.appRouting(status)).foldsUnderstanding)
        }
        #expect(Self.turn(Self.runtime(finished: true)).foldsUnderstanding)
    }

    @Test func anAnswerWithoutChangesKeepsItInView() {
        #expect(!Self.turn(.noChange("已经是这样")).foldsUnderstanding)
        #expect(!Self.turn(.outOfScope("不能测速")).foldsUnderstanding)
        #expect(!Self.turn(.clarify("哪个出口？", options: [])).foldsUnderstanding)
        #expect(!Self.turn(.failure(message: "超时", opensSettings: false, canUseLocal: true)).foldsUnderstanding)
        #expect(!Self.turn(.running).foldsUnderstanding)
    }

    /// Without steps there is no meta line to open, so folding would hide it for good.
    @Test func withoutStepsNothingIsFolded() {
        #expect(!Self.turn(Self.proposal(.written), steps: []).foldsUnderstanding)
    }

    @Test func anEmptyRestatementIsNotFolded() {
        #expect(!Self.turn(Self.proposal(.written), understanding: "").foldsUnderstanding)
        #expect(!Self.turn(Self.proposal(.written), understanding: nil).foldsUnderstanding)
    }
}
