import AppKit
import SwiftUI
import Testing
@testable import VeerUI

/// The minimum for text in the HIG's Accessibility page, for the colors Veer chooses itself. Not for
/// Increase Contrast: `NSAppearance(named:)` hands back the plain appearance for those names.
@MainActor struct AccentContrastTests {
    private let minimum = 4.5

    private func resolve(_ color: Color, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }

    private func luminance(_ color: NSColor) -> Double {
        // White, for one, is a gray with no red, green or blue to read until it is converted.
        let color = color.usingColorSpace(.sRGB) ?? color
        func linear(_ value: CGFloat) -> Double {
            value <= 0.03928 ? Double(value) / 12.92 : pow((Double(value) + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let lighter = max(luminance(first), luminance(second)), darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func labelsReadOnTheFill(_ name: NSAppearance.Name) throws {
        #expect(contrast(try resolve(.onAccent, in: name), try resolve(.accentFill, in: name)) >= minimum)
    }

    @Test func smallTextReadsOnWhite() throws {
        for color in [Color.veerAccent, .statusWarning, .statusFailure] {
            #expect(contrast(try resolve(color, in: .aqua), .white) >= minimum)
        }
    }

    /// A selected node: a delay in any status color on a wash of the accent, at its strongest.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func delaysReadOnASelectedTile(_ name: NSAppearance.Name) throws {
        let page = try resolve(.surfaceRaised, in: name)
        let wash = try #require(page.usingColorSpace(.sRGB)?.blended(withFraction: 0.14, of: try resolve(.veerAccent, in: name)))
        for color in [Color.statusSuccess, .statusWarning, .statusFailure] {
            #expect(contrast(try resolve(color, in: name), wash) >= minimum)
        }
    }

    @Test func theAccentReadsOnADarkWindow() throws {
        #expect(contrast(try resolve(.veerAccent, in: .darkAqua), try resolve(.surface, in: .darkAqua)) >= minimum)
    }
}
