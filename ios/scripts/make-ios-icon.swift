// iOS prototype app icon: the Mac icon's artwork (macos/scripts/make-icon.swift) as a full-bleed,
// opaque 1024 px square, because iOS applies its own mask.
//   swift ios/scripts/make-ios-icon.swift ios/VeerMobile/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    // iOS: the system masks the icon, so fill the whole opaque square with the same wash and map
    // the Mac body (100…924) onto the full canvas.
    let wash = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xE9E9E6)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(wash, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    context.translateBy(x: 512, y: 512)
    context.scaleBy(x: 1024 / 824, y: 1024 / 824)
    context.translateBy(x: -512, y: -512)
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

let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, render(pixels: 1024), nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
print(output.path)
