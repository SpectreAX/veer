import VeerCore

/// Demonstrations never verify URLs or search the public network, even if a future recorded
/// response contains a search/rule-set operation. Missing collaborators must not fall back to
/// the production defaults in EditorEngine.
nonisolated struct FixtureRuleVerifier: RuleSetVerifying {
    func verify(_ urls: [String]) async -> [String: RuleSetVerification] {
        Dictionary(uniqueKeysWithValues: Set(urls).map { ($0, .unverified) })
    }
}

nonisolated struct FixtureRuleSearch: RuleSearching {
    func search(_ queries: [String], config: SearchConfig) async -> [SearchRecord] { [] }
}
