import Foundation
import Testing
@testable import VeerCore

/// 配置体检: each kind of finding, no false positives, and fixes that go through PlanApplier.
struct HealthCheckTests {
    static func config(groups: String = "", rules: [String], providers: String = "", extra: String = "") -> String {
        """
        mode: rule
        proxies:
          - {name: A, type: ss, server: a.example.invalid, port: 1, cipher: aes-128-gcm, password: x}
          - {name: B, type: ss, server: b.example.invalid, port: 1, cipher: aes-128-gcm, password: x}
        proxy-groups:
          - {name: 代理, type: select, proxies: [A, B]}
          - {name: 可跳过, type: select, proxies: [A, PASS]}
        \(groups)
        \(providers)
        \(extra)
        rules:
        \(rules.map { "  - \($0)" }.joined(separator: "\n"))

        """
    }

    static func kinds(_ findings: [HealthFinding]) -> [HealthFinding.Kind] { findings.map(\.kind) }

    @Test func sampleConfigHasNoFindings() {
        #expect(ConfigHealthCheck.run(SampleConfig.text).isEmpty)
    }

    @Test func noFalsePositivesOnOrdinaryRules() {
        // Narrow before broad, distinct matchers, IP rules that only look alike, logical rules.
        let text = Self.config(rules: [
            "DOMAIN,mail.google.com,DIRECT", "DOMAIN-SUFFIX,google.com,代理", "DOMAIN-KEYWORD,googleapis,代理",
            "DOMAIN-SUFFIX,cn,DIRECT", "DOMAIN-SUFFIX,xn,代理",
            "IP-CIDR,10.0.0.0/16,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,代理,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "IP-CIDR,192.168.1.0/24,代理",
            "GEOIP,CN,DIRECT", "GEOIP,CN,代理,src", "SRC-IP-CIDR,10.0.0.0/8,DIRECT",
            "AND,((DOMAIN,a.com),(NETWORK,UDP)),REJECT", "DOMAIN,a.com,代理", "MATCH,代理",
        ])
        #expect(ConfigHealthCheck.run(text).isEmpty)
    }

    @Test func shadowedRuleWithDecidingExitHasAFix() throws {
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,DIRECT", "DOMAIN,mail.google.com,代理", "DOMAIN-KEYWORD,ads,REJECT",
                                       "DOMAIN-SUFFIX,ads.example.com,代理", "IP-CIDR,10.0.0.0/8,DIRECT", "IP-CIDR,10.1.0.0/16,代理,no-resolve", "MATCH,代理"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.shadowedRule, .shadowedRule, .shadowedRule])
        #expect(findings.map(\.ruleIndex) == [1, 3, 5])
        #expect(findings.allSatisfy { $0.fixTitle != nil && !$0.fix.isEmpty })
        #expect(findings[0].reason.contains("第 1 条"))
    }

    @Test func shadowedRuleWithSameExitIsCertain() {
        let findings = ConfigHealthCheck.run(Self.config(rules: ["DOMAIN-SUFFIX,google.com,代理", "DOMAIN,mail.google.com,代理", "MATCH,DIRECT"]))
        #expect(Self.kinds(findings) == [.shadowedRule])
        #expect(findings[0].title == "规则永远不会命中")
        #expect(findings[0].reason.contains("出口相同"))
    }

    @Test func shadowedByAGroupIsOnlyCertainForTCP() throws {
        // UDP to an exit without UDP keeps matching, so the rule is not deleted: the fix moves it in
        // front of the rule that covers it, unchanged.
        let text = Self.config(rules: ["DOMAIN,a.com,代理", "DOMAIN-SUFFIX,google.com,代理", "DOMAIN,mail.google.com,DIRECT # 邮件直连", "MATCH,DIRECT"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.shadowedRule])
        #expect(findings[0].title.contains("TCP"))
        #expect(findings[0].fixTitle == "移到第 2 条之前")
        let result = try PlanApplier.apply(EditPlan(operations: findings[0].fix), to: try ConfigDocument.parse(text))
        #expect(try ConfigDocument.parse(result.candidate).rules == ["DOMAIN,a.com,代理", "DOMAIN,mail.google.com,DIRECT", "DOMAIN-SUFFIX,google.com,代理", "MATCH,DIRECT"])
        #expect(result.candidate.contains("DOMAIN,mail.google.com,DIRECT # 邮件直连"), "the moved rule keeps its comment")
        #expect(result.items.first?.kind == .moveRule)
        #expect(ConfigHealthCheck.run(result.candidate).isEmpty, "nothing left to report after the move")
    }

    @Test func exitsThatCanPassNeverShadow() {
        // A group that may be set to PASS, PASS itself, or a missing exit lets matching continue.
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,可跳过", "DOMAIN,mail.google.com,DIRECT",
                                       "DOMAIN-SUFFIX,youtube.com,PASS", "DOMAIN,m.youtube.com,DIRECT", "MATCH,DIRECT"])
        #expect(ConfigHealthCheck.run(text).isEmpty)
    }

    @Test func noResolveOnTheEarlierRuleDoesNotCover() {
        // The earlier rule never resolves domains; the later one does, so it still matches domains.
        let text = Self.config(rules: ["IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.1.0.0/16,代理", "MATCH,代理"])
        #expect(ConfigHealthCheck.run(text).isEmpty)
    }

    @Test func exactDuplicates() throws {
        let text = Self.config(rules: ["DOMAIN-SUFFIX,github.com,代理", "GEOIP,CN,DIRECT,no-resolve", "domain-suffix,GitHub.com,代理", "GEOIP,CN,DIRECT,no-resolve", "MATCH,代理"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.duplicateRule, .duplicateRule])
        #expect(findings.map(\.ruleIndex) == [2, 3])
        // Removing one copy keeps the other, even though both share the same prefix.
        let doc = try ConfigDocument.parse(text)
        let result = try PlanApplier.apply(EditPlan(operations: findings.flatMap(\.fix)), to: doc)
        #expect(try ConfigDocument.parse(result.candidate).rules == ["DOMAIN-SUFFIX,github.com,代理", "GEOIP,CN,DIRECT,no-resolve", "MATCH,代理"])
        #expect(result.items.map(\.kind) == [.removeRule, .removeRule])
    }

    @Test func missingReferences() {
        let text = """
        proxies:
          - {name: A, type: ss, server: a.example.invalid, port: 1, cipher: aes-128-gcm, password: x}
        proxy-groups:
          - {name: G, type: select, proxies: [A, 不存在的节点], use: [没有的订阅]}
        rules:
          - DOMAIN,a.com,不存在的组
          - DOMAIN,b.com,direct
          - RULE-SET,netflix,G
          - AND,((RULE-SET,ads),(NETWORK,UDP)),REJECT
          - MATCH,G

        """
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.missingTarget, .missingTarget, .missingRuleSet, .missingRuleSet, .missingMember, .missingMember])
        #expect(findings.allSatisfy { $0.severity == .error && $0.fix.isEmpty })
        #expect(findings[3].reason.contains("“ads”"))
    }

    @Test func emptyGroups() {
        let text = Self.config(groups: """
          - {name: 空组, type: select}
          - {name: 空列表, type: url-test, proxies: []}
          - {name: 全部, type: select, include-all: true}
        """, rules: ["MATCH,代理"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.emptyGroup, .emptyGroup])
        #expect(findings.map(\.subject) == ["空组", "空列表"])
    }

    @Test func unusedRuleProvidersAndTheirRemoval() throws {
        let providers = """
        rule-providers:
          # 广告
          ads:
            type: http
            behavior: domain
            url: https://example.invalid/ads.mrs
            path: ./ads.mrs
          netflix: {type: http, behavior: domain, url: "https://example.invalid/netflix.mrs", path: ./netflix.mrs}
          nested: {type: http, behavior: domain, url: "https://example.invalid/nested.mrs", path: ./nested.mrs}
          dns-only: {type: http, behavior: domain, url: "https://example.invalid/dns.mrs", path: ./dns.mrs}
          sub: {type: http, behavior: domain, url: "https://example.invalid/sub.mrs", path: ./sub.mrs}
        """
        let extra = """
        dns:
          nameserver-policy:
            "rule-set:dns-only": [223.5.5.5]
        sub-rules:
          s1:
            - RULE-SET,sub,DIRECT
        """
        let text = Self.config(rules: ["RULE-SET,netflix,代理", "OR,((RULE-SET,nested),(DOMAIN,x.com)),DIRECT", "MATCH,代理"], providers: providers, extra: extra)
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.unusedProvider])
        #expect(findings[0].subject == "ads")
        #expect(findings[0].fix == [.removeProvider(key: "ads")])

        let doc = try ConfigDocument.parse(text)
        let result = try PlanApplier.apply(EditPlan(operations: findings[0].fix), to: doc)
        #expect(result.items.map(\.kind) == [.removeProvider])
        let after = try ConfigDocument.parse(result.candidate)
        #expect(after.providers.map(\.key).sorted() == ["dns-only", "nested", "netflix", "sub"])
        #expect(!result.candidate.contains("广告") && !result.candidate.contains("ads.mrs"))
        #expect(ConfigHealthCheck.run(result.candidate).isEmpty)

        // A rule set a rule still uses is never removed.
        #expect(throws: EditorError.self) { try PlanApplier.apply(EditPlan(operations: [.removeProvider(key: "netflix")]), to: doc) }
    }

    @Test func removingTheLastProviderLeavesAnEmptyMapping() throws {
        let text = Self.config(rules: ["MATCH,代理"], providers: """
        rule-providers:
          ads: {type: http, behavior: domain, url: "https://example.invalid/ads.mrs", path: ./ads.mrs}
        """)
        let result = try PlanApplier.apply(EditPlan(operations: [.removeProvider(key: "ads")]), to: try ConfigDocument.parse(text))
        #expect(result.candidate.contains("rule-providers: {}"))
        #expect(try ConfigDocument.parse(result.candidate).providers.isEmpty)
    }

    @Test func missingMatch() {
        let findings = ConfigHealthCheck.run(Self.config(rules: ["DOMAIN,a.com,代理"]))
        #expect(Self.kinds(findings) == [.missingMatch])
        #expect(findings[0].fix.isEmpty)
    }

    @Test func matchThatIsNotLast() throws {
        let text = Self.config(rules: ["DOMAIN,a.com,代理", "MATCH,DIRECT", "DOMAIN,b.com,代理", "GEOIP,CN,DIRECT"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.matchNotLast])
        #expect(findings[0].ruleIndex == 1)
        #expect(findings[0].fix.count == 2)
        let result = try PlanApplier.apply(EditPlan(operations: findings[0].fix), to: try ConfigDocument.parse(text))
        #expect(try ConfigDocument.parse(result.candidate).rules == ["DOMAIN,a.com,代理", "MATCH,DIRECT"])

        // MATCH to a group: only rules with the same exit are certainly dead; the others can still
        // match UDP, so they move in front of MATCH instead.
        let partialText = Self.config(rules: ["MATCH,代理", "DOMAIN,b.com,DIRECT", "DOMAIN,c.com,代理"])
        let partial = ConfigHealthCheck.run(partialText)
        #expect(Self.kinds(partial) == [.matchNotLast])
        #expect(partial[0].fix == [.removeRuleAt(index: 2, rule: "DOMAIN,c.com,代理"),
                                   .moveRule(index: 1, rule: "DOMAIN,b.com,DIRECT", before: 0, beforeRule: "MATCH,代理")])
        #expect(partial[0].fixTitle == "删除 1 条、把 1 条移到 MATCH 之前")
        #expect(partial[0].reason.contains("只对 TCP 确定"))
        let fixed = try PlanApplier.apply(EditPlan(operations: partial[0].fix), to: try ConfigDocument.parse(partialText))
        #expect(try ConfigDocument.parse(fixed.candidate).rules == ["DOMAIN,b.com,DIRECT", "MATCH,代理"])
    }

    @Test func movesReplayOntoNewContentAndAreRefusedWhenStale() throws {
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,代理", "DOMAIN,mail.google.com,DIRECT", "MATCH,DIRECT"])
        let finding = try #require(ConfigHealthCheck.run(text).first)
        let plan = EditPlan(operations: finding.fix)
        let result = try PlanApplier.apply(plan, to: try ConfigDocument.parse(text))
        // The refreshed subscription adds a rule at the top, so every index shifts by one.
        let refreshed = Self.config(rules: ["DOMAIN,new.example,DIRECT", "DOMAIN-SUFFIX,google.com,代理", "DOMAIN,mail.google.com,DIRECT", "MATCH,DIRECT"])
        let edit = EditReplay.Edit(id: UUID(), prompt: "体检", plan: plan, accepted: [0], items: result.items, base: text)
        let replay = EditReplay.replay([edit], onto: refreshed)
        #expect(replay.edits[0].items.map(\.outcome) == [.applied])
        #expect(try ConfigDocument.parse(replay.text).rules == ["DOMAIN,new.example,DIRECT", "DOMAIN,mail.google.com,DIRECT", "DOMAIN-SUFFIX,google.com,代理", "MATCH,DIRECT"])
        // A rule that changed since the check is refused rather than moved.
        let changed = text.replacingOccurrences(of: "DOMAIN,mail.google.com,DIRECT", with: "DOMAIN,mail.google.com,代理")
        #expect(throws: EditorError.self) { try PlanApplier.apply(plan, to: try ConfigDocument.parse(changed)) }
    }

    @Test func staleIndexIsRefused() throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        #expect(throws: EditorError.self) { try PlanApplier.apply(EditPlan(operations: [.removeRuleAt(index: 0, rule: "DOMAIN,changed.com,DIRECT")]), to: doc) }
        #expect(throws: EditorError.self) { try PlanApplier.apply(EditPlan(operations: [.removeRuleAt(index: 99, rule: "MATCH,自动选择")]), to: doc) }
    }

    @Test func findingsThatNeedADecisionCarryAnAIInstructionOrAGroupToEdit() {
        let text = Self.config(rules: ["DOMAIN-SUFFIX,netflix.com,奈飞", "RULE-SET,ads,REJECT", "DOMAIN,a.com,代理", "DOMAIN,a.com,代理", "MATCH,DIRECT"])
        let findings = ConfigHealthCheck.run(text)
        let target = findings.first { $0.kind == .missingTarget }
        #expect(target?.aiInstruction?.contains("第 1 条规则 DOMAIN-SUFFIX,netflix.com,奈飞 的出口“奈飞”在配置里不存在") == true)
        #expect(target?.aiInstruction?.contains("请先问我") == true)
        let ruleSet = findings.first { $0.kind == .missingRuleSet }
        #expect(ruleSet?.aiInstruction?.contains("规则集“ads”") == true && ruleSet?.aiInstruction?.contains("出口“REJECT”") == true)
        // A local fix needs no AI.
        #expect(findings.first { $0.kind == .duplicateRule }?.aiInstruction == nil)

        let empty = ConfigHealthCheck.run("proxies: []\nproxy-groups:\n  - {name: 待补, type: select}\nrules:\n  - MATCH,DIRECT\n")
        #expect(empty.first?.kind == .emptyGroup && empty.first?.editsGroup == "待补" && empty.first?.aiInstruction == nil)
        #expect(empty.first?.hint?.contains("编辑成员") == true)
    }

    @Test func aMissingMatchIsAddedAsTheLastRule() throws {
        let text = Self.config(rules: ["DOMAIN,a.com,代理", "DOMAIN,b.com,DIRECT"])
        #expect(ConfigHealthCheck.run(text).map(\.kind) == [.missingMatch])
        let document = try ConfigDocument.parse(text)
        let plan = EditPlan(operations: [.addMatch(targetId: document.target(named: "代理")!.id)])
        let result = try PlanApplier.apply(plan, to: document)
        #expect(try ConfigDocument.parse(result.candidate).rules == ["DOMAIN,a.com,代理", "DOMAIN,b.com,DIRECT", "MATCH,代理"])
        #expect(result.items.first?.kind == .addMatch)
        #expect(ConfigHealthCheck.run(result.candidate).isEmpty)
        // Never a second MATCH; replaying onto content that already has one changes nothing.
        #expect(throws: EditorError("配置里已经有 MATCH 规则。")) { try PlanApplier.apply(plan, to: try ConfigDocument.parse(result.candidate)) }
        let edit = EditReplay.Edit(id: UUID(), prompt: "体检", plan: plan, accepted: [0], items: result.items, base: text)
        #expect(EditReplay.replay([edit], onto: result.candidate).edits[0].items.map(\.outcome) == [.unchanged("新内容里已经有 MATCH 规则。")])
    }

    @Test func errorsComeFirst() {
        let text = Self.config(rules: ["DOMAIN,a.com,代理", "DOMAIN,a.com,代理", "DOMAIN,b.com,没有"])
        #expect(ConfigHealthCheck.run(text).map(\.severity) == [.error, .warning, .notice])
    }

    @Test func fixedConfigsPassMihomo() async throws {
        guard ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil else { return }
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,DIRECT", "DOMAIN,mail.google.com,代理", "DOMAIN,x.com,代理", "DOMAIN,x.com,代理", "MATCH,代理", "DOMAIN,y.com,代理"],
                               providers: "rule-providers:\n  ads: {type: http, behavior: domain, format: mrs, url: \"https://example.invalid/ads.mrs\", path: ./ads.mrs}")
        let findings = ConfigHealthCheck.run(text)
        let result = try PlanApplier.apply(EditPlan(operations: findings.flatMap(\.fix)), to: try ConfigDocument.parse(text))
        #expect(ConfigHealthCheck.run(result.candidate).isEmpty)
        #expect(await MihomoValidator().validate(result.candidate).status == .passed)
    }
}
