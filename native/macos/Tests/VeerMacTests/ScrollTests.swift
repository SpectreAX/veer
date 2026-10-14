import Testing
@testable import VeerMac

@Test @MainActor func layoutGrowthDoesNotDisableFollowing() {
    var state = ConversationScrollState()
    state.observeBottom(false)
    #expect(state.following)
    #expect(!state.atBottom)
}

@Test @MainActor func readingHistorySurvivesNewContentUntilExplicitResume() {
    var state = ConversationScrollState()
    state.beginInteraction()
    state.observeBottom(false)
    state.endInteraction(atBottom: false)
    state.observeBottom(false)
    #expect(!state.following)
    state.resume()
    #expect(state.following)
    #expect(!state.userScrolling)
}

@Test @MainActor func manuallyReachingBottomResumesFollowing() {
    var state = ConversationScrollState()
    state.beginInteraction()
    state.observeBottom(false)
    state.endInteraction(atBottom: true)
    #expect(state.following && state.atBottom)
}
