// Draws the Veer app icon and packages it as Resources/AppIcon.icns:
//
//   swift scripts/make-icon.swift [Resources/AppIcon.icns]
//
// The icon sits on Apple's macOS icon grid: a 1024 × 1024 canvas with an 824 × 824 superellipse
// body, so the system shows it at the same size and shape as other apps. The mark is the product
// in one gesture: a route that runs straight on, and a green branch that veers off it at a
// precise junction (a rule sending some traffic another way). Colors are DESIGN.md's: a quiet
// neutral surface, graphite ink, and Veer green as the one accent.
import CoreGraphics
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's icon body is close to a superellipse with exponent 5.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / exponent), c), y: rect.midY + b * copysign(pow(abs(s), 2 / exponent), s))
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let shape = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))

    // Body: a quiet surface with the faintest vertical light, the grid's soft shadow and a hairline edge.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    context.addPath(shape)
    context.setFillColor(color(0xF7F7F5))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let wash = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xE9E9E6)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(wash, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()
    context.addPath(shape)
    context.setStrokeColor(color(0x000000, 0.08))
    context.setLineWidth(3)
    context.strokePath()

    let ink = color(0x3A3A3C), green = color(0x1F9E54), surface = color(0xF4F4F2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    func stroke(_ path: CGPath, _ strokeColor: CGColor) {
        context.addPath(path)
        context.setStrokeColor(strokeColor)
        context.setLineWidth(68)
        context.strokePath()
    }
    func dot(_ center: CGPoint, radius: CGFloat, fill: CGColor, ring: CGColor? = nil) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(fill)
        context.fillEllipse(in: rect)
        if let ring {
            context.setStrokeColor(ring)
            context.setLineWidth(26)
            context.strokeEllipse(in: rect)
        }
    }
    // The trunk runs straight up; the branch leaves it at the junction and bends to the right.
    let junction = CGPoint(x: 430, y: 430)
    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: 430, y: 236))
    trunk.addLine(to: CGPoint(x: 430, y: 788))
    let branch = CGMutablePath()
    branch.move(to: junction)
    branch.addCurve(to: CGPoint(x: 700, y: 690), control1: CGPoint(x: 430, y: 590), control2: CGPoint(x: 700, y: 520))
    branch.addLine(to: CGPoint(x: 700, y: 788))
    stroke(trunk, ink)
    stroke(branch, green)
    dot(junction, radius: 50, fill: surface, ring: ink)
    dot(CGPoint(x: 700, y: 788), radius: 34, fill: green)
    return context.makeImage()!
}

// The sizes an .icns carries: 16–512 points at 1x and 2x.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let destination = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, render(pixels: points * scale), nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(name)") }
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print(output.path)
