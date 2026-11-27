import Foundation
import Testing
@testable import VeerCore

/// The faster lookups give the answers the slower ones did: one expression per kind instead of one
/// per place, flags read without an array, names and notices remembered.
struct NodeLocationSpeedTests {
    /// The flag reader as it was: every adjacent pair of scalars, from an array.
    static func flagAsItWas(_ name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        for index in scalars.indices.dropLast() {
            let first = scalars[index].value, second = scalars[index + 1].value
            guard (0x1F1E6...0x1F1FF).contains(first), (0x1F1E6...0x1F1FF).contains(second) else { continue }
            let code = String(UnicodeScalar(first - 0x1F1E6 + 0x41)!) + String(UnicodeScalar(second - 0x1F1E6 + 0x41)!)
            if NodeLocator.place(code) != nil { return code }
        }
        return nil
    }

    static func locateAsItWas(_ name: String) -> String? {
        flagAsItWas(name) ?? NodeLocator.earliest(in: name, entries: NodeLocator.oneByOne(.chinese))
            ?? NodeLocator.earliest(in: name, entries: NodeLocator.oneByOne(.english))
            ?? NodeLocator.earliest(in: name, entries: NodeLocator.oneByOne(.codes))
    }

    static func infoAsItWas(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if NodeCleanup.infoPhrases.contains(where: { lowered.contains($0) }) { return true }
        return NodeCleanup.infoPatterns.contains { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A small deterministic generator, so a failure names the same input on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11 ^ state << 7
        }
    }

    /// Names built from every word Veer knows, in mixed case, glued to letters, digits and
    /// separators in the ways subscriptions write them, with relays and words that say nothing.
    static func corpus(count: Int) -> [String] {
        var random = Seeded(state: 20_261_127)
        let words = Array(NodeLocator.chinese.codes.keys) + Array(NodeLocator.english.codes.keys) + Array(NodeLocator.codes.codes.keys)
        let fillers = ["", " ", "-", "_", "|", " | ", "[A]", "x", "IPLC", "IEPL", "0.5x", "专线", "中转", "高速", "s", "es", "ia", "us", "in", "Plus",
                       "节点", "01", "02 ", "Ü", "İ", "ß", "é", "🇯🇵", "🇺🇳", "🇦", "status", "russia", "→", "（", "）", "#", "UK", "Uk", "hk"]
        func cased(_ word: String) -> String {
            switch Int.random(in: 0..<4, using: &random) {
            case 0: word.uppercased()
            case 1: word.capitalized
            case 2: String(word.enumerated().map { $0.offset % 2 == 0 ? Character($0.element.uppercased()) : $0.element })
            default: word
            }
        }
        return (0..<count).map { _ in
            var name = ""
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                name += fillers.randomElement(using: &random)!
                if Bool.random(using: &random) { name += cased(words.randomElement(using: &random)!) }
            }
            return name + fillers.randomElement(using: &random)!
        }
    }

    @Test func locateAgreesWithOneExpressionPerPlace() {
        let fixed = ["🇯🇵日本东京01-0.1倍", "[A]HK PrivateNET 01", "中国香港 01", "广港专线 香港 02", "沪日 IEPL 东京", "Los Angeles 03", "Tokyo-02 x1.5",
                     "JP-02", "UK London", "新加坡-香港 中转", "香港-日本", "日本-香港", "美国 洛杉矶", "洛杉矶 美国", "São Paulo", "SÃO PAULO 01",
                     "Türkiye 01", "TÜRKIYE", "hong kong", "HongKong", "hongkongese", "russia status", "us-only plus", "USA 01", "UAE Dubai",
                     "New York → London", "印度尼西亚 雅加达", "印度 孟买", "澳大利亚 悉尼", "澳门 01", "台湾 台北 新北", "🇦🇯🇵", "🇺🇳 节点", "DIRECT", ""]
        let names = fixed + Self.corpus(count: 20_000)
        let differing = names.filter { NodeLocator.locate($0) != Self.locateAsItWas($0) }
        #expect(differing.isEmpty, "differs for \(differing.prefix(10))")
        // The corpus does reach the places: most names name one, and many do not.
        let located = names.filter { NodeLocator.locate($0) != nil }.count
        #expect(located > names.count / 3 && located < names.count)
    }

    @Test func flagsAreReadAsBefore() {
        var random = Seeded(state: 7)
        let scalars = (0x1F1E6...0x1F1FF).compactMap(Unicode.Scalar.init) + ["A", "J", " ", "中", "\u{200D}", "\u{FE0F}"].compactMap(\.unicodeScalars.first)
        let names = (0..<5000).map { _ in
            var view = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0...6, using: &random) { view.append(scalars.randomElement(using: &random)!) }
            return String(view)
        } + ["🇯🇵 东京", "东京 🇯🇵", "🇦🇯🇵", "🇺🇳", "🇺🇸🇯🇵", ""]
        for name in names {
            #expect(NodeLocator.flag(in: name) == Self.flagAsItWas(name), "\(name.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(NodeLocator.hasFlag(name) == (Self.flagAsItWas(name) != nil))
        }
    }

    @Test func placesKeepTheirFlagsNamesAndOrder() {
        for place in NodeLocator.places {
            let flag = String(String.UnicodeScalarView(place.code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 - 0x41 + $0.value) }))
            #expect(place.flag == flag)
            let language = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
            #expect(place.name == Locale(identifier: language).localizedString(forRegionCode: place.code) ?? place.code)
        }
        let sorted = NodeLocator.places.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        #expect(NodeLocator.sortedPlaces.map(\.code) == sorted.map(\.code))
        #expect(NodeLocator.allPlaces.map(\.code) == NodeLocator.places.map(\.code))
    }

    @Test func noticesAreFoundAsBefore() {
        let fixed = ["剩余流量：123.45 GB", "套餐到期：2026-12-31", "Expire: 2026/12/31", "官网 www.example.invalid", "香港 0.5x 倍率", "Node 1Gbps",
                     "12.5gb left", "12.5 Gb", "1 TB", "TB 1", "2026年12月31日", "1926-01-01", "20261231", "t.me/veer", "TRAFFIC", "JP 01"]
        let names = fixed + Self.corpus(count: 3000) + Self.corpus(count: 500).map { "\($0) \(Int.random(in: 1...999)) GB" }
        for name in names {
            let expected = Self.infoAsItWas(name)
            #expect(NodeCleanup.isInfoNode(name) == expected, "\(name)")
            // Again, from the memo.
            #expect(NodeCleanup.isInfoNode(name) == expected)
        }
    }

    @Test func boundedCacheEmptiesPastItsLimit() {
        let cache = BoundedCache<Int>(limit: 3)
        for (index, key) in ["a", "b", "c", "d"].enumerated() { cache.set(key, index) }
        #expect(cache.get("d") == 3)
        cache.set("e", 4)
        #expect(cache.get("a") == nil && cache.get("e") == 4)
    }
}
