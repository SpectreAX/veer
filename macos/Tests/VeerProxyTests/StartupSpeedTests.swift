import Foundation
import Testing
@testable import VeerCore
@testable import VeerProxy

/// The pieces a start spends its time in, with the shapes that used to make them slow.
@Suite struct StartupSpeedTests {
    @Test func escapedCharactersComeBackWherePlainOnesAndBadOnesStay() {
        let readable = ConfigImporter.readableUnicode(#"a: "\U0001F1EF\U0001F1F5 东京"\#nb: "\\U0001F600 kept"\#nc: plain\#n"#)
        // An escaped backslash before U is text, not an escape.
        #expect(readable == #"a: "🇯🇵 东京"\#nb: "\\U0001F600 kept"\#nc: plain\#n"#)
        // A number that is no character stays as written, and the text around it is kept.
        #expect(ConfigImporter.readableUnicode(#"a: "\UFFFFFFFF \U0001F600" # end"#) == #"a: "\UFFFFFFFF 😀" # end"#)
        #expect(ConfigImporter.readableUnicode("no escapes: 🇯🇵\n") == "no escapes: 🇯🇵\n")
    }

    @Test func aSubscriptionFullOfFlagsIsConvertedInOnePass() {
        // 4,000 escapes in 300 KB: replacing in place took seconds; one pass takes milliseconds.
        let line = #"  - {name: "\U0001F1FA\U0001F1F8 node", server: example.com, port: 443, type: ss, cipher: aes-128-gcm, password: x}"# + "\n"
        let yaml = "proxies:\n" + String(repeating: line, count: 2000)
        let clock = ContinuousClock()
        var readable = ""
        let took = clock.measure { readable = ConfigImporter.readableUnicode(yaml) }
        #expect(!readable.contains("\\U") && readable.components(separatedBy: "🇺🇸").count == 2001)
        #expect(took < .seconds(1))
    }

    @Test func leadingRulesGoInTogetherInOrderWithoutSecondCopies() {
        let block = "rules:\n  # mine\n  - DOMAIN,a.com,DIRECT\n  - 'RULE-SET,veer-hot-2,B'\n  - MATCH,A\n"
        let text = TopLevelBlocks.prepending(["'RULE-SET,veer-hot-1,A'", "'RULE-SET,veer-hot-2,B'"], toSequence: block)
        #expect(text == "rules:\n  - 'RULE-SET,veer-hot-1,A'\n  - 'RULE-SET,veer-hot-2,B'\n  # mine\n  - DOMAIN,a.com,DIRECT\n  - MATCH,A\n")
    }

    @Test func rulesNotWrittenAsABlockAreLeftToTheFullParse() {
        #expect(TopLevelBlocks.prepending(["X"], toSequence: "rules: [a, b]\n") == nil)
        #expect(TopLevelBlocks.prepending(["X"], toSequence: "rules:\n  - a\n - b\n") == nil)
    }

    @Test func theDiagnosticsBundleCarriesTheLatestStart() {
        let with = Diagnostics.collect(appVersion: "1", coreVersion: nil, settings: RuntimeSettings(), state: nil, effectiveConfig: nil,
                                       logs: [], coreTail: [], startup: "proxyReady         +212 ms  (200 ms)")
        #expect(with.first { $0.name == "startup.txt" }?.text == "proxyReady         +212 ms  (200 ms)\n")
        let without = Diagnostics.collect(appVersion: "1", coreVersion: nil, settings: RuntimeSettings(), state: nil, effectiveConfig: nil,
                                          logs: [], coreTail: [])
        #expect(!without.contains { $0.name == "startup.txt" })
    }
}
