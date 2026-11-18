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

/// The world map's own coordinates: the unit square, x from the west to the east edge and y from
/// the northern latitude shown to the southern one, in an equirectangular projection.
public enum MapProjection {
    /// Latitudes shown: Antarctica and the far north add nothing here.
    public static let north = 84.0, south = -58.0
    /// Width over height of the map as drawn.
    public static let aspect = 360 / (north - south)

    public static func unit(longitude: Double, latitude: Double) -> CGPoint {
        let clamped = min(max(latitude, south), north)
        return CGPoint(x: (longitude + 180) / 360, y: (north - clamped) / (north - south))
    }

    public static func coordinate(_ unit: CGPoint) -> (longitude: Double, latitude: Double) {
        (unit.x * 360 - 180, north - unit.y * (north - south))
    }
}

/// How many nodes a region has, as one of the map's steps of green; 0 is none.
public enum MapTier {
    public static let lowerBounds = [1, 3, 10, 20]

    public static func tier(_ count: Int) -> Int { lowerBounds.filter { count >= $0 }.count }
}

/// What part of the map is in view: how far it is magnified, and the unit-square point at the
/// view's center. The whole map is `world`.
public struct MapViewport: Equatable, Sendable {
    public var scale: CGFloat
    public var center: CGPoint

    public static let world = MapViewport(scale: 1, center: CGPoint(x: 0.5, y: 0.5))
    public static let scales: ClosedRange<CGFloat> = 1...8

    public init(scale: CGFloat, center: CGPoint) {
        let scale = min(max(scale, Self.scales.lowerBound), Self.scales.upperBound)
        // The map never leaves an edge of the view empty.
        let margin = 0.5 / scale
        self.scale = scale
        self.center = CGPoint(x: min(max(center.x, margin), 1 - margin), y: min(max(center.y, margin), 1 - margin))
    }

    /// Shows a region with room around it: `bounds` takes about `fill` of the view's shorter need,
    /// no closer than `closest`, and never further out than a region needs to be told from the map.
    public static func showing(_ bounds: CGRect, fill: CGFloat = 0.42, closest: CGFloat = 6, widest: CGFloat = 1.6) -> MapViewport {
        let extent = max(bounds.width, bounds.height, 0.0001)
        return MapViewport(scale: min(max(fill / extent, widest), closest), center: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// A unit-square point in a view of `size`.
    public func point(_ unit: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: ((unit.x - center.x) * scale + 0.5) * size.width, y: ((unit.y - center.y) * scale + 0.5) * size.height)
    }

    /// The unit-square point under a point of the view.
    public func unit(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return center }
        return CGPoint(x: (point.x / size.width - 0.5) / scale + center.x, y: (point.y / size.height - 0.5) / scale + center.y)
    }

    public func transform(in size: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: scale * size.width, b: 0, c: 0, d: scale * size.height,
                          tx: (0.5 - center.x * scale) * size.width, ty: (0.5 - center.y * scale) * size.height)
    }

    /// Dragged by `translation` points of the view.
    public func panned(by translation: CGSize, in size: CGSize) -> MapViewport {
        guard size.width > 0, size.height > 0 else { return self }
        return MapViewport(scale: scale, center: CGPoint(x: center.x - translation.width / (scale * size.width),
                                                         y: center.y - translation.height / (scale * size.height)))
    }
}

extension MapCountry {
    /// Where the country is on the map: the bounds of its largest ring, so that far-off islands and
    /// land across the date line (Alaska's chain, Russia's east) do not stretch it across the world.
    public var unitBounds: CGRect {
        var best = CGRect.null, bestArea: CGFloat = -1
        for ring in rings {
            var box = CGRect.null
            for point in ring where point.count >= 2 {
                let unit = MapProjection.unit(longitude: point[0], latitude: point[1])
                box = box.union(CGRect(origin: unit, size: .zero))
            }
            let area = box.width * box.height
            if area > bestArea {
                best = box
                bestArea = area
            }
        }
        return best
    }
}
