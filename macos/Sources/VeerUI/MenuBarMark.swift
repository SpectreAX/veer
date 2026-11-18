import AppKit

/// Veer's mark for the menu bar: the app icon's route and the branch that veers off it, without the
/// icon's body, as a template image the system tints for a light or dark bar and any wallpaper.
/// The same geometry as `scripts/make-icon.swift`, on the icon's 1024-point grid, with heavier
/// strokes and a larger junction so it reads at 18 points.
public enum MenuBarMark {
    /// The mark's size in the menu bar.
    public static let size = NSSize(width: 14, height: 18)
    /// What the mark occupies on the icon's grid: its strokes and dots, and nothing of the body.
    static let bounds = CGRect(x: 370, y: 190, width: 400, height: 644)

    public static let image: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func draw(in context: CGContext, rect: CGRect) {
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        context.translateBy(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(84)
        context.setStrokeColor(.black)
        context.setFillColor(.black)
        let junction = CGPoint(x: 430, y: 430)
        // The trunk runs straight up; the branch leaves it at the junction and bends to the right.
        context.move(to: CGPoint(x: 430, y: 240))
        context.addLine(to: CGPoint(x: 430, y: 784))
        context.strokePath()
        context.move(to: junction)
        context.addCurve(to: CGPoint(x: 700, y: 690), control1: CGPoint(x: 430, y: 590), control2: CGPoint(x: 700, y: 520))
        context.addLine(to: CGPoint(x: 700, y: 760))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: 700 - 62, y: 772 - 62, width: 124, height: 124))
        // The junction: a ring, as on the icon.
        context.fillEllipse(in: CGRect(x: junction.x - 88, y: junction.y - 88, width: 176, height: 176))
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: junction.x - 36, y: junction.y - 36, width: 72, height: 72))
        context.setBlendMode(.normal)
    }
}
