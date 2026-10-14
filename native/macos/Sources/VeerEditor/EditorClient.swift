import Foundation

public struct StrategyGroup: Codable, Equatable, Sendable {
    public var name: String
    public var region: String
    public init(name: String, region: String) { self.name = name; self.region = region }
}

public struct Draft: Codable, Equatable, Sendable {
    public var groups: [StrategyGroup]
    public var rules: String
    public init(groups: [StrategyGroup] = [], rules: String = "rules: []\n") { self.groups = groups; self.rules = rules }
}

public struct AISettings: Codable, Equatable, Sendable {
    public var baseUrl = "https://api.deepseek.com"
    public var model = "deepseek-chat"
    public var apiKey = ""
    public var useSavedKey = false
    public init() {}
}

public struct Validation: Codable, Equatable, Sendable {
    public let status: String
    public let message: String
}

public struct RuleChange: Codable, Sendable {
    public let kind: String
    public let matchType: String
    public let match: String
    public let target: String?
    public let before: [String]
    public let after: String?
}

public struct DiffPart: Codable, Sendable {
    public let kind: String
    public let text: String
}

public struct Preview: Codable, Sendable {
    public let candidate: String
    public let summaries: [RuleChange]
    public let warnings: [String]
    public let diff: [DiffPart]
    public let changed: Bool
    public let validation: Validation
}

public struct InspectResult: Codable, Sendable { public let count: Int }
public struct KeyStatus: Codable, Sendable { public let saved: Bool }
private struct APIError: Decodable { let error: String }
private struct KeyRequest: Encodable { let baseUrl: String; var apiKey: String? }
private struct PlanRequest: Encodable {
    let groups: [StrategyGroup]
    let rules: String
    let prompt: String
    let mode: String
    let settings: AISettings?
}
private struct DocumentRequest: Encodable {
    let yaml: String
    var groups: [StrategyGroup] = []
    var rules: String = "rules: []\n"
    var prompt: String = ""
    var mode: String = "local"
    var settings: AISettings?
}
private struct ExportedDocument: Decodable { let yaml: String }

public struct EditorFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct EditorClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    public init(port: Int = 4317) throws {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else { throw EditorFailure("本机服务端口无效。") }
        baseURL = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 95
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }

    private func post<Input: Encodable, Output: Decodable>(_ path: String, _ input: Input) async throws -> Output {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/" + path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(input)
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw EditorFailure("本机服务响应无效。") }
            var data = Data()
            let maximumResponseBytes = path.hasPrefix("document/") ? 8 * 1024 * 1024 : 1024 * 1024
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else { throw EditorFailure("本机服务响应超过 \(maximumResponseBytes / 1024 / 1024) MB，请缩小配置。") }
                data.append(byte)
            }
            guard http.statusCode == 200 else {
                if let error = try? JSONDecoder().decode(APIError.self, from: data) { throw EditorFailure(String(error.error.prefix(500))) }
                throw EditorFailure("本机服务返回 HTTP \(http.statusCode)，请检查编辑服务。")
            }
            guard let result = try? JSONDecoder().decode(Output.self, from: data) else { throw EditorFailure("编辑服务协议不匹配，请更新并重启本机服务。") }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as EditorFailure { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw EditorFailure("无法连接本机编辑服务。请在 prototype/ai-editor 中运行 npm start 后重试。") }
    }

    public func importDocument(_ yaml: String) async throws -> Draft { try await post("document/import", DocumentRequest(yaml: yaml)) }
    public func exportDocument(_ yaml: String, draft: Draft) async throws -> String {
        let result: ExportedDocument = try await post("document/export", DocumentRequest(yaml: yaml, groups: draft.groups, rules: draft.rules))
        return result.yaml
    }
    public func inspect(_ draft: Draft, source: String? = nil) async throws -> InspectResult {
        if let source { return try await post("document/inspect", DocumentRequest(yaml: source, groups: draft.groups, rules: draft.rules)) }
        return try await post("private/inspect", draft)
    }
    public func validate(_ draft: Draft, source: String? = nil) async throws -> Validation {
        if let source { return try await post("document/validate", DocumentRequest(yaml: source, groups: draft.groups, rules: draft.rules)) }
        return try await post("private/validate", draft)
    }
    public func generate(_ draft: Draft, prompt: String, mode: String, settings: AISettings, source: String? = nil) async throws -> Preview {
        if let source { return try await post("document/plan", DocumentRequest(yaml: source, groups: draft.groups, rules: draft.rules, prompt: prompt, mode: mode, settings: mode == "ai" ? settings : nil)) }
        return try await post("private/plan", PlanRequest(groups: draft.groups, rules: draft.rules, prompt: prompt, mode: mode, settings: mode == "ai" ? settings : nil))
    }
    public func keyStatus(_ baseUrl: String) async throws -> KeyStatus { try await post("key/status", KeyRequest(baseUrl: baseUrl)) }
    public func saveKey(_ settings: AISettings) async throws -> KeyStatus { try await post("key/save", KeyRequest(baseUrl: settings.baseUrl, apiKey: settings.apiKey)) }
}
