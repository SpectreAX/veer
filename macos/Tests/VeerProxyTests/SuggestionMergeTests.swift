import Foundation
import Testing
@testable import VeerProxy

struct SuggestionMergeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// `count` failures of `host` through `exit`, a second apart; the last one's suggestion.
    private func fail(_ detector: inout SuggestionDetector, _ host: String, exit: String?, at time: Date, count: Int = 3) -> Suggestion? {
        var last: Suggestion?
        for step in 0..<count { last = detector.connectionFailed(host: host, exit: exit, at: time.addingTimeInterval(Double(step))) }
        return last
    }

    @Test func hostsFailingThroughOneExitBecomeOneSuggestion() {
        var detector = SuggestionDetector()
        #expect(fail(&detector, "github.com", exit: "Proxy", at: start)?.kind == .failing(host: "github.com", count: 3))
        #expect(fail(&detector, "chatgpt.com", exit: "Proxy", at: start.addingTimeInterval(10))?.kind == .failing(host: "chatgpt.com", count: 3))
        // The third host through the same exit: one cause.
        let merged = fail(&detector, "www.google.com", exit: "Proxy", at: start.addingTimeInterval(20))
        #expect(merged?.kind == .outage(exit: "Proxy", hosts: ["chatgpt.com", "github.com", "www.google.com"]))
        #expect(merged?.id == "outage:Proxy")
        // A fourth joins the same suggestion.
        let grown = fail(&detector, "www.youtube.com", exit: "Proxy", at: start.addingTimeInterval(30))
        #expect(grown?.kind == .outage(exit: "Proxy", hosts: ["chatgpt.com", "github.com", "www.google.com", "www.youtube.com"]))
        // More failures of a host it already names change nothing.
        #expect(detector.connectionFailed(host: "github.com", exit: "Proxy", at: start.addingTimeInterval(40)) == nil)
    }

    @Test func failuresWithNoExitInCommonStaySeparate() {
        var detector = SuggestionDetector()
        #expect(fail(&detector, "a.example.com", exit: "Proxy", at: start)?.id == "failing:a.example.com")
        #expect(fail(&detector, "b.example.com", exit: "Media", at: start)?.id == "failing:b.example.com")
        #expect(fail(&detector, "c.example.com", exit: "AI", at: start)?.id == "failing:c.example.com")
        // Where the log names no exit, there is no evidence of a shared cause.
        #expect(fail(&detector, "d.example.com", exit: nil, at: start)?.id == "failing:d.example.com")
        #expect(fail(&detector, "e.example.com", exit: nil, at: start)?.id == "failing:e.example.com")
        #expect(fail(&detector, "f.example.com", exit: nil, at: start)?.id == "failing:f.example.com")
    }

    @Test func aDismissedSuggestionStaysAwayForTheCooldown() {
        var detector = SuggestionDetector()
        let first = fail(&detector, "github.com", exit: nil, at: start)
        detector.dismiss(first!, at: start.addingTimeInterval(5))
        #expect(fail(&detector, "github.com", exit: nil, at: start.addingTimeInterval(60)) == nil)
        let later = start.addingTimeInterval(5 + SuggestionDetector.dismissCooldown + 1)
        #expect(fail(&detector, "github.com", exit: nil, at: later)?.id == "failing:github.com")
    }

    @Test func whatHasStoppedIsWithdrawn() {
        var detector = SuggestionDetector()
        _ = fail(&detector, "github.com", exit: nil, at: start)
        #expect(detector.resolved(at: start.addingTimeInterval(60)).isEmpty)
        #expect(detector.resolved(at: start.addingTimeInterval(SuggestionDetector.failureWindow + 5)) == ["failing:github.com"])
        // Withdrawn, so it can be raised again.
        #expect(fail(&detector, "github.com", exit: nil, at: start.addingTimeInterval(1000))?.id == "failing:github.com")

        // A slow node that answers again.
        _ = detector.tested(node: "HK 01", in: "Proxy", delay: nil, at: start)
        #expect(detector.tested(node: "HK 01", in: "Proxy", delay: 0, at: start)?.id == "slow:Proxy:HK 01")
        #expect(detector.tested(node: "HK 01", in: "Proxy", delay: 80, at: start) == nil)
        #expect(detector.resolved(at: start) == ["slow:Proxy:HK 01"])
    }

    @Test func theExitIsReadFromTheLogLine() {
        let line = "[TCP] dial 🚀 节点选择 (match RuleSet/openai) 127.0.0.1:52361(Safari) --> chatgpt.com:443 error: i/o timeout"
        #expect(SuggestionDetector.failedExit(inLog: line) == "🚀 节点选择")
        #expect(SuggestionDetector.failedHost(inLog: line) == "chatgpt.com")
        #expect(SuggestionDetector.failedExit(inLog: "[TCP] 127.0.0.1:1 --> example.com:443 match Match using Proxy") == nil)
    }

    @Test func theMostSeriousComesFirst() {
        let outage = Suggestion(kind: .outage(exit: "Proxy", hosts: ["a", "b", "c"]))
        let failing = Suggestion(kind: .failing(host: "x", count: 3))
        let slow = Suggestion(kind: .slowNode(group: "Proxy", node: "HK"))
        let unmatched = Suggestion(kind: .unmatched(host: "y", count: 5))
        #expect([unmatched, slow, failing, outage].sorted { $0.severity > $1.severity } == [outage, failing, slow, unmatched])
    }
}
