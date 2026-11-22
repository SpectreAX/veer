import Foundation
import Testing
@testable import VeerCore

struct AppRoutingTests {
    static let chrome = AppIdentity(kind: .bundle, name: "Google Chrome", bundleID: "com.google.Chrome",
                                    bundlePath: "/Applications/Google Chrome.app",
                                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", flavor: .chromium)
    static let curl = AppIdentity(kind: .executable, name: "curl", executablePath: "/usr/bin/curl", flavor: .commandLine)

    @Test func appBundleIsMatchedByPathNeverByBundleID() {
        let rule = AppRule(app: Self.chrome, target: .policy("Proxy"))
        let report = AppRuleBuilder.build([rule], policies: ["Proxy"])
        #expect(report.lines(of: rule.id).map(\.text) == ["PROCESS-PATH-WILDCARD,/Applications/Google Chrome.app/*,Proxy"])
        #expect(!report.ruleTexts.joined().contains("com.google.Chrome"))
        #expect(!report.ruleTexts.contains { $0.hasPrefix("PROCESS-NAME") })
        #expect(report.status(of: rule.id) == .active)
    }

    @Test func toolIsMatchedByExactPath() {
        let rule = AppRule(app: Self.curl, target: .direct)
        let report = AppRuleBuilder.build([rule], policies: [])
        #expect(report.ruleTexts == ["PROCESS-PATH,/usr/bin/curl,DIRECT"])
    }

    @Test func localNetworkGuardOnlyWhenSomethingLeavesDirect() {
        let direct = AppRuleBuilder.build([AppRule(app: Self.curl, target: .direct)], policies: [])
        #expect(!direct.lines.contains { $0.role == .localGuard })
        let proxied = AppRuleBuilder.build([AppRule(app: Self.curl, target: .reject)], policies: [])
        let guards = proxied.lines.prefix { $0.role == .localGuard }
        #expect(guards.count == AppRuleBuilder.localRanges.count + AppRuleBuilder.localRanges6.count)
        #expect(guards.allSatisfy { $0.text.hasSuffix(",DIRECT,no-resolve") })
        #expect(proxied.lines.last?.text == "PROCESS-PATH,/usr/bin/curl,REJECT")
    }

    @Test func pathsWithSyntaxCharactersBecomeWildcards() {
        let odd = AppIdentity(kind: .executable, name: "x", executablePath: "/opt/a,b (beta)/run*?")
        let report = AppRuleBuilder.build([AppRule(app: odd, target: .direct)], policies: [])
        #expect(report.ruleTexts == ["PROCESS-PATH-WILDCARD,/opt/a?b ?beta?/run??,DIRECT"])
        let bundle = AppIdentity(kind: .bundle, name: "B", bundlePath: "/Applications/Foo (Beta).app",
                                 executablePath: "/Applications/Foo (Beta).app/Contents/MacOS/Foo")
        let inLogic = AppRuleBuilder.build([AppRule(app: bundle, target: .followProfile,
                                                    domains: [.init(matchType: "DOMAIN-SUFFIX", value: "Example.COM", target: .direct)])], policies: [])
        #expect(inLogic.ruleTexts == ["AND,((PROCESS-PATH-WILDCARD,/Applications/Foo ?Beta?.app/*),(DOMAIN-SUFFIX,example.com)),DIRECT"])
    }

    @Test func namesStoredInEitherUnicodeFormBothMatch() {
        let name = "Caf\u{E9}"
        let app = AppIdentity(kind: .bundle, name: name, bundlePath: "/Applications/\(name).app",
                              executablePath: "/Applications/\(name).app/Contents/MacOS/x")
        let report = AppRuleBuilder.build([AppRule(app: app, target: .direct)], policies: [])
        #expect(report.ruleTexts.count == 2)
        #expect(Set(report.ruleTexts.map { $0.unicodeScalars.count }).count == 2)
        let chinese = AppIdentity(kind: .bundle, name: "网易云音乐", bundlePath: "/Applications/网易云音乐.app",
                                  executablePath: "/Applications/网易云音乐.app/Contents/MacOS/x")
        #expect(AppRuleBuilder.build([AppRule(app: chinese, target: .direct)], policies: []).ruleTexts.count == 1)
    }

    @Test func domainRoutesComeBeforeTheAppsOwnRule() {
        let rule = AppRule(app: Self.chrome, target: .policy("Proxy"),
                           domains: [.init(matchType: "DOMAIN-SUFFIX", value: "bank.example", target: .direct),
                                     .init(matchType: "DOMAIN", value: "ads.example", target: .reject)])
        let report = AppRuleBuilder.build([rule], policies: ["Proxy"])
        let own = report.lines(of: rule.id)
        #expect(own.map(\.role) == [.domain, .domain, .app])
        #expect(own[0].text == "AND,((PROCESS-PATH-WILDCARD,/Applications/Google Chrome.app/*),(DOMAIN-SUFFIX,bank.example)),DIRECT")
        // As Mihomo's /connections names the AND rule it matched.
        #expect(own[0].reportedPayload == "((ProcessPathWildcard,/Applications/Google Chrome.app/*) && (DomainSuffix,bank.example))")
        #expect(report.line(reportedType: "AND", payload: own[1].reportedPayload)?.domainID == rule.domains[1].id)
        #expect(report.line(reportedType: "ProcessPathWildcard", payload: "/Applications/Google Chrome.app/*")?.ruleID == rule.id)
    }

    @Test func missingExitsAreLeftOutAndReportedNeverSentDirect() {
        let rule = AppRule(app: Self.chrome, target: .policy("Gone"),
                           domains: [.init(matchType: "DOMAIN", value: "a.example", target: .policy("Also gone"))])
        let report = AppRuleBuilder.build([rule], policies: ["Proxy"])
        #expect(report.lines.isEmpty)
        #expect(report.status(of: rule.id) == .missingTargets(["Also gone", "Gone"]))
    }

    @Test func laterRulesForAnAppAlreadyTakenAreShadowed() {
        let first = AppRule(app: Self.chrome, target: .direct)
        let helper = AppIdentity(kind: .executable, name: "Helper",
                                 executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/"
                                     + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        let second = AppRule(app: helper, target: .reject)
        let disabled = AppRule(app: Self.curl, target: .reject, enabled: false)
        let follows = AppRule(app: Self.curl, target: .followProfile)
        let report = AppRuleBuilder.build([first, second, disabled, follows], policies: [])
        #expect(report.status(of: second.id) == .shadowed(by: first.id))
        #expect(report.status(of: disabled.id) == .disabled)
        #expect(report.status(of: follows.id) == .followsProfile)
        #expect(report.ruleTexts == ["PROCESS-PATH-WILDCARD,/Applications/Google Chrome.app/*,DIRECT"])
    }

    @Test func profileProcessRulesAreReportedAsOverruled() {
        let report = AppRuleBuilder.build([AppRule(app: Self.curl, target: .direct)], policies: [],
                                          profileRules: ["PROCESS-NAME,curl,Proxy", "DOMAIN,a.example,DIRECT", "AND,((PROCESS-PATH,/x),(NETWORK,UDP)),REJECT"])
        #expect(report.profileProcessRules == ["PROCESS-NAME,curl,Proxy", "AND,((PROCESS-PATH,/x),(NETWORK,UDP)),REJECT"])
    }

    @Test func connectionsAreAttributedByPathOnly() {
        let attribution = AppAttribution(apps: [Self.chrome, Self.curl])
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/"
            + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(attribution.app(forProcessPath: helper)?.id == Self.chrome.id)
        #expect(attribution.app(forProcessPath: "/applications/google chrome.app/Contents/MacOS/Google Chrome")?.id == Self.chrome.id)
        #expect(attribution.app(forProcessPath: "/Applications/Google Chrome.app2/x") == nil)
        #expect(attribution.app(forProcessPath: "/usr/bin/curl")?.id == Self.curl.id)
        #expect(attribution.app(forProcessPath: "/usr/local/bin/curl") == nil)
        #expect(attribution.app(forProcessPath: nil) == nil)
        #expect(attribution.app(forProcessPath: "") == nil)
        #expect(SharedProcesses.isShared(processName: "com.apple.WebKit.Networking", path: nil))
        #expect(!SharedProcesses.isShared(processName: "curl", path: "/usr/bin/curl"))
    }

    @Test func invalidDomainValuesAreDropped() {
        #expect(!AppRule.DomainRoute(matchType: "DOMAIN", value: "a,b", target: .direct).isValid)
        #expect(!AppRule.DomainRoute(matchType: "DOMAIN", value: "a.example", target: .followProfile).isValid)
        #expect(AppRule.DomainRoute(matchType: "DOMAIN-KEYWORD", value: "google", target: .direct).isValid)
    }

    @Test func rulesSurviveCoding() throws {
        let rule = AppRule(app: Self.chrome, target: .policy("Proxy"), domains: [.init(matchType: "DOMAIN", value: "a.example", target: .reject)])
        let data = try JSONEncoder().encode([rule])
        #expect(try JSONDecoder().decode([AppRule].self, from: data) == [rule])
    }
}
