import CoreGraphics
import Testing
import VeerUI

struct PanelWindowGrowthTests {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

    @Test func widensToTheRightWhenThereIsRoom() {
        let window = CGRect(x: 100, y: 200, width: 1080, height: 720)
        #expect(PanelWindowGrowth.grown(window, by: 380, within: screen) == CGRect(x: 100, y: 200, width: 1460, height: 720))
    }

    @Test func movesLeftAsLittleAsNeededNearTheEdge() {
        let window = CGRect(x: 500, y: 200, width: 1080, height: 720)
        let grown = PanelWindowGrowth.grown(window, by: 380, within: screen)
        #expect(grown == CGRect(x: 268, y: 200, width: 1460, height: 720))
        #expect(grown.maxX == screen.maxX)
    }

    @Test func neverGrowsWiderThanTheScreen() {
        let window = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let grown = PanelWindowGrowth.grown(window, by: 380, within: screen)
        #expect(grown == CGRect(x: 0, y: 0, width: 1728, height: 900))
        // Already the screen's width: unchanged, the panel takes the page's width.
        #expect(PanelWindowGrowth.grown(screen, by: 380, within: screen) == screen)
    }

    @Test func keepsAWindowAlreadyWiderThanTheScreenAsItIs() {
        let window = CGRect(x: -50, y: 0, width: 1900, height: 900)
        #expect(PanelWindowGrowth.grown(window, by: 380, within: screen) == window)
    }

    @Test func followsAWindowOnASecondScreen() {
        let second = CGRect(x: 1728, y: 0, width: 1920, height: 1050)
        let window = CGRect(x: 1800, y: 50, width: 900, height: 600)
        #expect(PanelWindowGrowth.grown(window, by: 400, within: second) == CGRect(x: 1800, y: 50, width: 1300, height: 600))
    }

    @Test func shrinksBackButNotBelowTheMinimum() {
        let window = CGRect(x: 100, y: 200, width: 1460, height: 720)
        #expect(PanelWindowGrowth.shrunk(window, by: 380, minWidth: 860) == CGRect(x: 100, y: 200, width: 1080, height: 720))
        #expect(PanelWindowGrowth.shrunk(CGRect(x: 0, y: 0, width: 1000, height: 600), by: 380, minWidth: 860).width == 860)
    }

    @Test func comparesFramesWithinHalfAPoint() {
        let frame = CGRect(x: 500, y: 200, width: 1080, height: 720)
        #expect(PanelWindowGrowth.same(frame, frame.offsetBy(dx: 0.2, dy: 0)))
        #expect(!PanelWindowGrowth.same(frame, frame.insetBy(dx: 1, dy: 0)))
    }
}
