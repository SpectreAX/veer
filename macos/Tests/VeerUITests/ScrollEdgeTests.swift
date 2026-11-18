import Foundation
import Testing
@testable import VeerUI

/// Pages decide how to lay themselves out around a bar on `ScrollEdge.available`, so it has to say
/// exactly whether this system draws the edge effect: from macOS 26, and not before.
struct ScrollEdgeTests {
    @Test func barsWithAnEdgeEffectAreAvailableFromMacOS26() {
        let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        #expect(ScrollEdge.available == ProcessInfo.processInfo.isOperatingSystemAtLeast(macOS26))
    }
}
