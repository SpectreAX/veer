import Foundation
import Testing
@testable import VeerProxy
import VeerCore

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
}
