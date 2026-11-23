import Testing
@testable import VeerApp

/// The Connections filters keep showing what they filter by.
@MainActor struct ConnectionFiltersTests {
    @Test func aChosenValueStaysAnOptionAfterItsConnectionsClose() {
        #expect(ConnectionFilters.options(live: ["Safari", "git", "Safari", ""], chosen: nil) == ["Safari", "git"])
        // zoom.us has no live connection: still listed, so the picker names it and it can be changed back.
        #expect(ConnectionFilters.options(live: ["Safari", "git"], chosen: "zoom.us") == ["Safari", "git", "zoom.us"])
        #expect(ConnectionFilters.options(live: ["Safari"], chosen: "Safari") == ["Safari"])
    }

    @Test func theFilterMenuCountsWhatIsInUse() {
        #expect(ConnectionFilters().isEmpty)
        let two = ConnectionFilters(process: "git", policy: "DIRECT")
        #expect(!two.isEmpty && two.count == 2)
    }
}
