import Foundation
import Testing
@testable import VeerCore

/// One node's delay test and names with characters a URL path treats specially.
struct ControllerDelayTests {
    typealias FakeCore = MihomoControllerTests.FakeCore

    @Test func eachAnswerOfTheDelayEndpointIsItsOwnOutcome() async throws {
        let core = FakeCore()
        core.answers["GET /proxies/JP 01/delay"] = (200, #"{"delay":123}"#)
        core.answers["GET /proxies/Dead/delay"] = (504, #"{"message":"Timeout"}"#)
        core.answers["GET /proxies/Bad/delay"] = (503, #"{"message":"An error occurred in the delay test"}"#)
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: "s", transport: core.transport)
        #expect(try await controller.testDelay(proxy: "JP 01") == .delay(123))
        #expect(try await controller.testDelay(proxy: "Dead") == .timedOut)
        #expect(try await controller.testDelay(proxy: "Bad") == .failed("An error occurred in the delay test"))
        await #expect(throws: EditorError.self) { try await controller.testDelay(proxy: "Unknown") }
        let query = core.requests.first?.url?.query ?? ""
        #expect(query.contains("timeout=5000") && query.contains("url="))
    }

    @Test func aSlashInANameStaysInOneSegmentAndIsEscapedOnce() async throws {
        let core = FakeCore()
        core.answers["PUT /proxies/港/台"] = (204, "")
        core.answers["GET /proxies/港/台"] = (200, #"{"name":"港/台","type":"Selector","now":"HK"}"#)
        core.answers["PUT /providers/rules/veer/hot"] = (204, "")
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: "s", transport: core.transport)
        try await controller.select("HK", in: "港/台")
        #expect(try await controller.selection(of: "港/台") == "HK")
        try await controller.refreshRuleProvider("veer/hot")
        let paths = core.requests.compactMap { $0.url?.absoluteString }
        #expect(paths.allSatisfy { !$0.contains("%25") })
        #expect(paths.first?.hasSuffix("/proxies/%E6%B8%AF%2F%E5%8F%B0") == true)
    }
}
