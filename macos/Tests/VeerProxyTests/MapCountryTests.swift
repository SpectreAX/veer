import Foundation
import Testing
import VeerCore
@testable import VeerProxy

struct MapCountryTests {
    static let countries: [MapCountry] = {
        let url = LocalizationTests.root.appendingPathComponent("Resources/Map/countries-110m.json")
        return (try? JSONDecoder().decode([MapCountry].self, from: Data(contentsOf: url))) ?? []
    }()

    static func code(longitude: Double, latitude: Double) -> String? {
        countries.first { $0.contains(longitude: longitude, latitude: latitude) }?.code
    }

    @Test func theResourceLoads() {
        #expect(Self.countries.count > 150)
    }

    @Test(arguments: [("JP", 138.5, 36.5), ("US", -100.0, 40.0), ("US", -150.0, 64.0), ("FR", 2.5, 47.0), ("DE", 10.0, 51.0),
                      ("TW", 121.0, 23.7), ("KR", 127.8, 36.5), ("GB", -1.5, 53.0), ("AU", 134.0, -25.0), ("BR", -52.0, -10.0)])
    func placesAreInTheirCountries(code: String, longitude: Double, latitude: Double) {
        #expect(Self.code(longitude: longitude, latitude: latitude) == code)
    }

    @Test func theOceanIsNoCountry() {
        #expect(Self.code(longitude: -40, latitude: 30) == nil)
        #expect(Self.code(longitude: 170, latitude: 10) == nil)
    }

    /// Lesotho is a hole in South Africa's outline.
    @Test func aHoleIsNotInside() {
        #expect(Self.code(longitude: 28.2, latitude: -29.6) == "LS")
        #expect(Self.code(longitude: 25.0, latitude: -30.0) == "ZA")
    }

    /// Veer's regions that are the dot alone at this scale; a new one means a check of the map.
    @Test func regionsWithoutAShapeAreOnlyTheSmallOnes() {
        let shapes = Set(Self.countries.compactMap(\.code))
        let missing = NodeLocator.allPlaces.map(\.code).filter { !shapes.contains($0) }
        #expect(Set(missing).isSubset(of: ["SG", "HK", "MO", "MT", "BH", "MU", "LU", "MC", "LI", "AD", "IM", "JE", "GG", "GI", "BM", "KY", "BS", "BB", "SC", "MV", "CV", "QA", "PR", "AW"]), "\(missing)")
    }

    @Test func dotsFarApartStayPut() {
        let points = ["JP": CGPoint(x: 900, y: 100), "US": CGPoint(x: 200, y: 120)]
        let placed = MapDots.spread(points, spacing: 26, in: CGSize(width: 1000, height: 400))
        for (code, point) in points {
            #expect(placed[code]?.x == point.x && placed[code]?.y == point.y)
        }
    }

    @Test func crowdedDotsEndUpApart() {
        let points = ["GB": CGPoint(x: 480, y: 90), "NL": CGPoint(x: 495, y: 88), "DE": CGPoint(x: 505, y: 95), "FR": CGPoint(x: 490, y: 102),
                      "same": CGPoint(x: 490, y: 102)]
        let placed = MapDots.spread(points, spacing: 26, in: CGSize(width: 1000, height: 400))
        let list = Array(placed.values)
        for (index, a) in list.enumerated() {
            for b in list[(index + 1)...] {
                #expect(hypot(a.x - b.x, a.y - b.y) >= 25.5)
            }
        }
        for (code, point) in placed { #expect(hypot(point.x - points[code]!.x, point.y - points[code]!.y) < 60) }
    }

    @Test func dotsStayInsideTheMap() {
        let placed = MapDots.spread(["a": CGPoint(x: 1, y: 1), "b": CGPoint(x: 3, y: 1)], spacing: 26, in: CGSize(width: 300, height: 100))
        for point in placed.values { #expect(point.x >= 13 && point.y >= 13) }
    }

    @Test func nodeCountsFallIntoTheLegendsSteps() {
        #expect([0, 1, 2, 3, 9, 10, 19, 20, 233].map(MapTier.tier) == [0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    @Test func aViewOfTheMapConvertsPointsBothWaysAndStaysOnTheMap() {
        let size = CGSize(width: 800, height: 315)
        #expect(MapViewport.world.point(CGPoint(x: 0.5, y: 0.5), in: size) == CGPoint(x: 400, y: 157.5))
        #expect(MapViewport.world.point(CGPoint(x: 0, y: 0), in: size) == .zero)
        let near = MapViewport(scale: 4, center: CGPoint(x: 0.8, y: 0.3))
        let unit = CGPoint(x: 0.82, y: 0.31)
        let there = near.point(unit, in: size), back = near.unit(there, in: size)
        #expect(abs(back.x - unit.x) < 1e-9 && abs(back.y - unit.y) < 1e-9)
        let transformed = unit.applying(near.transform(in: size))
        #expect(abs(transformed.x - there.x) < 1e-9 && abs(transformed.y - there.y) < 1e-9)
        // Never past an edge: at 4x the center stays an eighth of the map from each side.
        let corner = MapViewport(scale: 4, center: CGPoint(x: 0.99, y: 0.01))
        #expect(corner.center == CGPoint(x: 0.875, y: 0.125))
        #expect(MapViewport(scale: 0.2, center: CGPoint(x: 0.1, y: 0.9)) == .world)
        #expect(MapViewport(scale: 99, center: CGPoint(x: 0.5, y: 0.5)).scale == 8)
        // Dragging right moves the view west.
        #expect(near.panned(by: CGSize(width: 80, height: 0), in: size).center.x < near.center.x)
    }

    @Test func aRegionIsShownWithRoomAroundIt() throws {
        let japan = try #require(Self.countries.first { $0.code == "JP" }).unitBounds
        let view = MapViewport.showing(japan)
        #expect(view.scale > 1.6 && view.scale <= 6)
        #expect(abs(view.center.x - japan.midX) < 0.01 && abs(view.center.y - japan.midY) < 0.01)
        // A country that crosses the date line is where its mainland is, not the whole width.
        let usa = try #require(Self.countries.first { $0.code == "US" }).unitBounds
        #expect(usa.width < 0.25 && usa.midX < 0.3)
        let russia = try #require(Self.countries.first { $0.code == "RU" }).unitBounds
        #expect(russia.width < 0.6 && russia.midX > 0.5)
        // The widest view still tells a large country from the whole map.
        #expect(MapViewport.showing(russia).scale >= 1.6)
        let point = MapProjection.unit(longitude: 139.7, latitude: 35.7)
        let coordinate = MapProjection.coordinate(point)
        #expect(abs(coordinate.longitude - 139.7) < 1e-9 && abs(coordinate.latitude - 35.7) < 1e-9)
    }
}
