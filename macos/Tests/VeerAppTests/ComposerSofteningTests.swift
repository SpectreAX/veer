import CoreGraphics
import Testing
@testable import VeerApp

@Suite struct ComposerSofteningTests {
    @Test func aViewSoftensWithHowMuchOfItIsUnderTheComposer() {
        let edge: CGFloat = 500
        // Above the composer: untouched, however close.
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 460, width: 300, height: 40), edge: edge) == 0)
        // Half under, all under, and past it.
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 480, width: 300, height: 40), edge: edge) == 0.5)
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 500, width: 300, height: 40), edge: edge) == 1)
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 600, width: 300, height: 40), edge: edge) == 1)
    }

    @Test func tenthsKeepSmallMovesFromReportingAndShortLinesRampOverTwentyFourPoints() {
        let edge: CGFloat = 500
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 461, width: 300, height: 40), edge: edge) == 0)
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 462, width: 300, height: 40), edge: edge) == 0.1)
        // A 17 pt line is measured against 24 pt, so it does not jump to full in a few points.
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 495, width: 300, height: 17), edge: edge) == 0.5)
    }

    @Test func containersAndPlacesWithoutAComposerNeverSoften() {
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 450, width: 300, height: 200), edge: 500) == 0)
        #expect(SoftenedUnderComposer.fraction(of: CGRect(x: 0, y: 480, width: 300, height: 40), edge: nil) == 0)
    }
}
