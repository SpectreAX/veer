import Foundation
import VeerCore

/// A recorded stand-in for an AI service, so the Agent can be shown in the Simulator without a
/// key or a network (brief v0.3: "a recorded fixture if none"). Never presented as a live answer:
/// every turn it answers runs on `FixtureAI.model`, and the UI labels those turns
/// "示例回答（未连接 AI）" (`FixtureAI.isFixture(_:)`) once, at the top of the turn.
///
/// Whatever the instruction, it proposes one route: the first domain in the instruction
/// (else example.com) goes DIRECT. That is the smallest proposal the engine accepts, applies to
/// any profile, and needs no rule-set download. The connection test and the model list fail as
/// if offline: there is no service behind it.
nonisolated struct FixtureAITransport: AITransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, request.httpMethod == "POST", let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // `listModels` (a GET): nothing to list.
            throw URLError(.notConnectedToInternet)
        }
        let (system, user) = Self.prompts(in: object)
        // `AIClient.testConnection` asks for {"ok":true}; a fixture is not a working service.
        if user == "ping" || system.contains("{\"ok\":true}") { throw URLError(.notConnectedToInternet) }
        let content = try Self.answer(system: system, user: user, chinese: Self.prefersChinese)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (try Self.wrap(content, for: url), response)
    }

    static var prefersChinese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true }

    /// The system prompt and the last user message, in any of the three wire formats.
    static func prompts(in body: [String: Any]) -> (system: String, user: String) {
        func text(_ content: Any?) -> String {
            if let string = content as? String { return string }
            let parts = content as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        var system = text(body["system"])
        if let instruction = body["systemInstruction"] as? [String: Any] { system = text(instruction["parts"]) }
        var user = ""
        if let messages = body["messages"] as? [[String: Any]] {
            if let first = messages.first, first["role"] as? String == "system" { system = text(first["content"]) }
            user = messages.last { $0["role"] as? String == "user" }.map { text($0["content"]) } ?? ""
        } else if let contents = body["contents"] as? [[String: Any]] {
            user = contents.last { $0["role"] as? String == "user" }.map { text($0["parts"]) } ?? ""
        }
        return (system, user)
    }

    /// The reply the engine reads: a one-route plan. The turn itself carries the
    /// "示例回答（未连接 AI）" label once (`FixtureAI.isFixture(_:)`), so the
    /// understanding is plain, per the design review.
    static func answer(system: String, user: String, chinese: Bool) throws -> String {
        // The anonymized config (in the system prompt, or the message on older prompts) lists
        // built-ins as `- {id: target-N, name: DIRECT}`.
        guard let direct = firstMatch(#"id:\s*"?(target-\d+)"?\s*,\s*name:\s*"?DIRECT"?\s*\}"#, in: system + "\n" + user) else {
            throw URLError(.cannotParseResponse)
        }
        let domain = self.domain(in: instruction(in: user)) ?? "example.com"
        let understanding = chinese
            ? "\(domain) 及其子域名直连。"
            : "\(domain) and its subdomains go DIRECT."
        let reply: [String: Any] = [
            "understanding": understanding,
            "schemaVersion": 1,
            "operations": [["kind": "route", "matchType": "DOMAIN-SUFFIX", "match": domain, "targetId": direct]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The user's own words: the request puts them after "指令：".
    static func instruction(in user: String) -> String {
        guard let range = user.range(of: "指令：\n", options: .backwards) else { return user }
        let rest = user[range.upperBound...]
        return String(rest.components(separatedBy: "\n\n").first ?? String(rest))
    }

    /// The first domain-looking word, lowercased, without a leading "www." or "*.".
    static func domain(in text: String) -> String? {
        guard var found = firstMatch(#"(?i)(?<![\w.-])((?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24})(?![\w-])"#, in: text)?.lowercased() else {
            return nil
        }
        for prefix in ["*.", "www."] where found.hasPrefix(prefix) { found.removeFirst(prefix.count) }
        return found
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The content in the response shape of the endpoint asked.
    static func wrap(_ content: String, for url: URL) throws -> Data {
        let path = url.path()
        let object: [String: Any]
        if path.hasSuffix("/messages") {
            object = ["type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": content]]]
        } else if path.contains(":generateContent") || path.contains(":streamGenerateContent") {
            object = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": content]]]]]]
        } else {
            object = ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// Fixture mode: how it is turned on, what it runs with, and which turns it answered.
enum FixtureAI {
    /// `-VeerFixtureAI YES` as a launch argument (UserDefaults' argument domain), or
    /// `VEER_FIXTURE_AI=1` in the environment, or the debug switch (`AppModel.setFixtureMode`).
    static let launchKey = "VeerFixtureAI"
    /// The model fixture turns record (`Turn.mode == .ai(model: model)`): the per-turn flag.
    static let model = "veer-fixture"
    /// A reserved name (RFC 2606): nothing would answer even if a request escaped.
    static let baseURL = "https://fixture.veer.invalid/v1"
    static let key = "fixture-no-key"

    static func requested(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        defaults.bool(forKey: launchKey) || environment["VEER_FIXTURE_AI"] == "1"
    }

    /// What fixture turns run on: an OpenAI-format service at a reserved address, its fixture model.
    static var settings: AISettings { AISettings(provider: .openAI, baseURL: baseURL, model: model, thinkingLevel: .off) }

    /// A turn the fixture answered, which the UI must label "示例回答（未连接 AI）".
    static func isFixture(_ turn: Turn) -> Bool {
        if case .ai(let label) = turn.mode { return label == model || label.hasPrefix(model + " ") }
        return false
    }

    /// The label for such a turn.
    static var label: String { String(localized: "示例回答（未连接 AI）") }
}

/// API keys in memory only, for fixture mode and tests: nothing reaches the Keychain or disk.
nonisolated final class MemoryKeyStore: KeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    init(_ keys: [String: String] = [:]) { self.keys = keys }

    func read(for provider: String) -> String? { lock.withLock { keys[provider] } }
    func save(_ key: String, for provider: String) throws { lock.withLock { keys[provider] = key } }
    func delete(for provider: String) { lock.withLock { keys[provider] = nil } }
}
