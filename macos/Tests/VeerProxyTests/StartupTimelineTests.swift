import Foundation
import Testing
@testable import VeerProxy

@Suite struct StartupTimelineTests {
    @Test func stepsComeInTheOrderReachedWithTheTimeEachTook() {
        let began = ContinuousClock.now
        var timeline = StartupTimeline(began: began)
        timeline.mark(.controllerReady, at: began + .milliseconds(240))
        timeline.mark(.configReady, at: began + .milliseconds(180))
        timeline.mark(.processStarted, at: began + .milliseconds(200))
        #expect(timeline.steps.map(\.milestone) == [.configReady, .processStarted, .controllerReady])
        #expect(timeline.steps.map { StartupTimeline.milliseconds($0.took) } == [180, 20, 40])
        #expect(timeline.time(of: .proxyReady) == nil)
    }

    @Test func aSecondProcessStartReplacesTheFirst() {
        let began = ContinuousClock.now
        var timeline = StartupTimeline(began: began)
        timeline.mark(.processStarted, at: began + .milliseconds(100))
        timeline.mark(.processStarted, at: began + .milliseconds(900))
        #expect(timeline.steps.count == 1)
        #expect(timeline.time(of: .processStarted) == .milliseconds(900))
    }

    @Test func milestonesAtTheSameInstantKeepTheirNaturalOrder() {
        let began = ContinuousClock.now
        var timeline = StartupTimeline(began: began)
        timeline.mark(.proxyReady, at: began + .milliseconds(50))
        timeline.mark(.controllerReady, at: began + .milliseconds(50))
        #expect(timeline.steps.map(\.milestone) == [.controllerReady, .proxyReady])
    }

    @Test func theReportHasOneLinePerStep() {
        let began = ContinuousClock.now
        var timeline = StartupTimeline(began: began)
        timeline.mark(.configReady, at: began + .milliseconds(12))
        timeline.mark(.proxyReady, at: began + .milliseconds(212))
        #expect(timeline.report == "configReady        +12 ms  (12 ms)\nproxyReady         +212 ms  (200 ms)")
    }

    @Test func pollingIsQuickAtFirstThenEases() {
        #expect(ReadinessPolling.interval(after: .zero) == .milliseconds(20))
        #expect(ReadinessPolling.interval(after: .milliseconds(1999)) == .milliseconds(20))
        #expect(ReadinessPolling.interval(after: .seconds(2)) == .milliseconds(100))
        #expect(ReadinessPolling.loadingLimit < ReadinessPolling.limit)
    }
}
