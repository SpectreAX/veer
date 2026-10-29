import Foundation
import Testing
@testable import VeerCore

struct NodeLocationTests {
    @Test(arguments: [
        ("🇯🇵日本东京01-0.1倍 | 电信联通推荐", "JP"),
        ("🇸🇬AWS新加坡01 | 电信移动联通推荐", "SG"),
        ("🇺🇸美国圣何塞01 | 三网推荐", "US"),
        ("🇹🇼台湾2 | 避免晚高峰使用", "TW"),
        ("[A]HK PrivateNET 01", "HK"),
        ("[A]FR PublicNET 03", "FR"),
        ("香港 IPLC 01", "HK"),
        ("中国香港 01", "HK"),
        ("广港专线 香港 02", "HK"),
        ("沪日 IEPL 东京", "JP"),
        ("Los Angeles 03", "US"),
        ("Tokyo-02 x1.5", "JP"),
        ("JP-02", "JP"),
        ("UK London", "GB"),
        ("Frankfurt | 0.5x", "DE"),
        ("土耳其 伊斯坦布尔", "TR"),
        ("新加坡-香港 中转", "SG"),
        ("🇨🇳 回国专线", "CN"),
    ])
    func locatesNodes(name: String, code: String) {
        #expect(NodeLocator.locate(name) == code)
    }

    @Test(arguments: ["[A]AI JUST FOR AGENT", "剩余流量：995.9 GB", "Russia? no: status", "us-only plus", "节点 01", "DIRECT"])
    func leavesUnknownNamesAlone(name: String) {
        // "status" and lower-case "us" are words, not the United States.
        if name.hasPrefix("Russia") { return #expect(NodeLocator.locate(name) == "RU") }
        #expect(NodeLocator.locate(name) == nil)
    }

    @Test func placesHaveFlagsAndCoordinates() throws {
        let japan = try #require(NodeLocator.place("jp"))
        #expect(japan.flag == "🇯🇵")
        #expect((-90...90).contains(japan.latitude) && (-180...180).contains(japan.longitude))
        #expect(Set(NodeLocator.places.map(\.code)).count == NodeLocator.places.count)
    }

    /// Coverage on a real subscription: `VEER_LOCATE_PROFILE=/path/to/profile.yaml`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_LOCATE_PROFILE"] != nil))
    func coverageOnARealProfile() throws {
        let paths = ProcessInfo.processInfo.environment["VEER_LOCATE_PROFILE"]!.split(separator: ":").map(String.init)
        for path in paths {
            let document = try ConfigDocument.parse(String(contentsOfFile: path, encoding: .utf8))
            let nodes = document.targets.filter { $0.kind == .node && !NodeCleanup.isInfoNode($0.name) }
            let missed = nodes.filter { NodeLocator.locate($0.name) == nil }.map(\.name)
            let share = Double(nodes.count - missed.count) / Double(max(nodes.count, 1))
            print("coverage \(path.split(separator: "/").last!): \(nodes.count - missed.count)/\(nodes.count) = \(Int(share * 100))%; missed: \(missed)")
            #expect(share >= 0.9)
        }
    }
}
