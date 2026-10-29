import Foundation
import Testing
@testable import VeerCore

/// `/connections` as Mihomo sends it.
struct ConnectionDecodingTests {
    static let json = #"""
    {"downloadTotal":10,"uploadTotal":5,"connections":[{"id":"c1","metadata":{"network":"tcp","type":"HTTPS","sourceIP":"127.0.0.1",
    "destinationIP":"104.16.1.1","destinationPort":"443","host":"github.com","process":"Safari","processPath":"/Applications/Safari.app"},
    "upload":1200,"download":3456789,"start":"2026-10-29T13:05:01.123456+08:00","chains":["HK 01","Auto","Proxy"],
    "rule":"RuleSet","rulePayload":"Github"},{"id":"c2","metadata":{"network":"udp","host":""}}]}
    """#

    @Test func trafficAndStartDecode() throws {
        struct List: Decodable { let connections: [MihomoController.Connection] }
        let list = try JSONDecoder().decode(List.self, from: Data(Self.json.utf8))
        let first = list.connections[0]
        #expect(first.upload == 1200 && first.download == 3_456_789)
        #expect(first.metadata.process == "Safari" && first.chains == ["HK 01", "Auto", "Proxy"])
        let start = try #require(first.start)
        #expect(abs(start.timeIntervalSince1970 - 1_793_250_301.123) < 0.01)
        // Fields the core leaves out take defaults.
        #expect(list.connections[1].upload == 0 && list.connections[1].start == nil && list.connections[1].rule.isEmpty)
    }

    @Test func logLinesDecode() throws {
        let line = try JSONDecoder().decode(MihomoController.LogLine.self, from: Data(#"{"type":"warning","payload":"dial failed"}"#.utf8))
        #expect(line == MihomoController.LogLine(type: "warning", payload: "dial failed"))
    }
}

struct DNSQueryDecodingTests {
    @Test func decodesTheControllersAnswer() throws {
        let json = #"{"AD":false,"Status":0,"Question":[{"Name":"github.com.","Qtype":1,"Qclass":1}],"Answer":[{"TTL":36,"data":"20.205.243.166","name":"github.com.","type":1}]}"#
        let result = try JSONDecoder().decode(MihomoController.DNSResult.self, from: Data(json.utf8))
        #expect(result.status == 0)
        #expect(result.answers == [MihomoController.DNSAnswer(name: "github.com.", type: 1, ttl: 36, data: "20.205.243.166")])
        #expect(result.answers[0].typeName == "A")
        let none = try JSONDecoder().decode(MihomoController.DNSResult.self, from: Data(#"{"Status":3}"#.utf8))
        #expect(none.status == 3 && none.answers.isEmpty)
    }
}
