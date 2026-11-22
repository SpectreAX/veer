import Testing
@testable import VeerApp

/// Settings → Proxy → Proxy port: which typed text may replace the saved port. The field saves only
/// when editing ends, so a prefix of an out-of-range number (6553 of 65536) is never saved on its own.
@MainActor struct ProxyPortEntryTests {
    @Test func onlyAPortInRangeMayBeSaved() {
        #expect(ProxySettings.port(from: "8899") == 8899)
        #expect(ProxySettings.port(from: "1024") == 1024)
        #expect(ProxySettings.port(from: "65535") == 65535)
        for text in ["", "abc", "80", "1023", "65536", "123456", " 8899", "88a9", "-1"] {
            #expect(ProxySettings.port(from: text) == nil, "\(text) must leave the saved port")
        }
    }

    @Test func emptyTextNeedsNoWarningButNamesNoPort() {
        #expect(ProxySettings.portProblem("") == nil)
        #expect(ProxySettings.port(from: "") == nil)
        #expect(ProxySettings.portProblem("abc") != nil)
        #expect(ProxySettings.portProblem("65536") != nil)
        #expect(ProxySettings.portProblem("6553") == nil)
    }

    /// The field never ends an edit showing a value that is not the saved port without a warning.
    @Test func endingAnEditShowsTheSavedPortWhenNothingCanBeSaved() {
        #expect(ProxySettings.textAfterEdit("8899", saved: 8899, leaving: false) == "8899")
        #expect(ProxySettings.textAfterEdit("8899", saved: 8899, leaving: true) == "8899")
        // Empty shows only the placeholder, which is not the saved port, so it goes back even on Return.
        #expect(ProxySettings.textAfterEdit("", saved: 9090, leaving: false) == "9090")
        #expect(ProxySettings.textAfterEdit("", saved: 9090, leaving: true) == "9090")
        // Text with a problem keeps its warning on Return, and goes back once the edit is left.
        for text in ["abc", "80", "65536", "123456"] {
            #expect(ProxySettings.textAfterEdit(text, saved: 9090, leaving: false) == text)
            #expect(ProxySettings.textAfterEdit(text, saved: 9090, leaving: true) == "9090")
        }
    }
}
