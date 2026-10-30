import Foundation

/// A country's outline on the node map, from Natural Earth's 1:110m countries (public domain).
public struct MapCountry: Decodable, Sendable {
    /// ISO 3166-1 alpha-2; none for the few places without one.
    public let code: String?
    /// Rings of [longitude, latitude]; holes are rings too, so inside means an odd count.
    public let rings: [[[Double]]]

    public func contains(longitude: Double, latitude: Double) -> Bool {
        var inside = false
        for ring in rings {
            var previous = ring[ring.count - 1]
            for point in ring {
                if (point[1] > latitude) != (previous[1] > latitude),
                   longitude < (previous[0] - point[0]) * (latitude - point[1]) / (previous[1] - point[1]) + point[0] {
                    inside.toggle()
                }
                previous = point
            }
        }
        return inside
    }
}

/// Where a map's dots go: each at its place, except that dots closer than `spacing` push each other
/// apart until all can be read and clicked. The result does not depend on which dot is chosen, so
/// choosing one moves nothing.
public enum MapDots {
    public static func spread(_ points: [String: CGPoint], spacing: CGFloat, in size: CGSize, passes: Int = 40) -> [String: CGPoint] {
        var placed = points
        let codes = points.keys.sorted()
        for _ in 0..<passes {
            var moved = false
            for (index, a) in codes.enumerated() {
                for b in codes[(index + 1)...] {
                    guard let pa = placed[a], let pb = placed[b] else { continue }
                    let dx = pb.x - pa.x, dy = pb.y - pa.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance < spacing else { continue }
                    // Two dots on the very same spot part sideways.
                    let (ux, uy) = distance > 0.01 ? (dx / distance, dy / distance) : (1, 0)
                    let push = (spacing - distance) / 2
                    placed[a] = clamp(CGPoint(x: pa.x - ux * push, y: pa.y - uy * push), to: size, margin: spacing / 2)
                    placed[b] = clamp(CGPoint(x: pb.x + ux * push, y: pb.y + uy * push), to: size, margin: spacing / 2)
                    moved = true
                }
            }
            if !moved { break }
        }
        return placed
    }

    private static func clamp(_ point: CGPoint, to size: CGSize, margin: CGFloat) -> CGPoint {
        CGPoint(x: min(max(point.x, margin), max(margin, size.width - margin)), y: min(max(point.y, margin), max(margin, size.height - margin)))
    }
}
