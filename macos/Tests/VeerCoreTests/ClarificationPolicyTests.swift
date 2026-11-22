import Foundation
import Testing
@testable import VeerCore

struct ClarificationPolicyTests {
    @Test func questionsForFactsAreToldApartFromChoices() {
        #expect(ClarificationPolicy.asksForFacts("请告诉我哪些 Google 域名需要直连？", options: []))
        #expect(ClarificationPolicy.asksForFacts("能提供具体的域名吗？", options: []))
        #expect(ClarificationPolicy.asksForFacts("Which domains should go direct?", options: []))
        // Where traffic should go is the user's choice.
        #expect(!ClarificationPolicy.asksForFacts("请告诉我这些流量走哪个出口。", options: []))
        #expect(!ClarificationPolicy.asksForFacts("要让哪些服务走日本？", options: []))
        // Ready-made options are a real question.
        #expect(!ClarificationPolicy.asksForFacts("哪些域名直连？有两种做法：", options: [ClarifyOption(label: "A", prompt: "a")]))
    }

    @Test func servicesAreFoundByNameWithTheirMainlandParts() {
        let catalog: Set<String> = ["google", "google-cn", "google@cn", "google@!cn", "apple", "apple-cn", "steam"]
        let found = InstructionLookup.services(in: "google 走美国，部分可直连域名走直连；苹果也一样", catalog: catalog)
        #expect(found.map(\.set) == ["google", "apple"])
        #expect(found.first?.mainland == ["google-cn", "google@cn"] && found.first?.outside == ["google@!cn"])
        // A name inside another word is not the service.
        #expect(InstructionLookup.services(in: "mysteamer.example 直连", catalog: catalog).isEmpty)
        // Without a catalog only the name is given, never a variant that may not exist.
        #expect(InstructionLookup.services(in: "google 直连", catalog: nil).first?.mainland == [])
        let message = LookupHints(domains: [], addresses: [], services: found).message
        #expect(message.contains("google-cn") && message.contains("没有实测"))
    }

    @Test func hintsSavedBeforeServicesStillLoad() throws {
        let old = #"{"domains":[{"domain":"x.com","ownSet":null,"others":[],"broad":[]}],"addresses":[]}"#
        let hints = try JSONDecoder().decode(LookupHints.self, from: Data(old.utf8))
        #expect(hints.domains.count == 1 && hints.services.isEmpty)
    }

    @Test func searchedRoutesToDirectAlwaysWaitForReview() {
        let direct = ChangeItem(id: 0, kind: .route, subject: "x", matchType: "DOMAIN-SUFFIX", match: "jal.com", targetName: "DIRECT",
                                targetID: "d", replaced: [], rule: "DOMAIN-SUFFIX,jal.com,DIRECT")
        #expect(ExecutionMode.needsReviewAfterSearch(items: [direct], searched: true))
        #expect(!ExecutionMode.needsReviewAfterSearch(items: [direct], searched: false))
    }
}
