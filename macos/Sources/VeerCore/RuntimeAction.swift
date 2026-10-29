import Foundation

/// Something the model asks Veer to do to the running core instead of changing the config:
/// switch a node, the mode, test delays, close connections. Groups and nodes are named by the
/// anonymized config's target ids, as plan operations are.
public enum RuntimeAction: Sendable, Equatable {
    case select(groupId: String, targetId: String)
    /// Test the group's members, then select the one with the lowest delay, among `regions` when given.
    case selectFastest(groupId: String, regions: [Region])
    case mode(String)
    case test(groupId: String)
    case closeConnections(host: String)

    public static let modes = ["rule", "global", "direct"]

    static func decode(_ raw: Any) throws -> RuntimeAction {
        guard let op = raw as? [String: Any], let kind = op["kind"] as? String else {
            throw EditorError("AI 返回了无效的运行状态操作。")
        }
        func fields(_ allowed: Set<String>) throws {
            guard Set(op.keys).isSubset(of: allowed) else { throw EditorError("AI 的运行状态操作包含不支持的字段，请重新生成。") }
        }
        func string(_ key: String) throws -> String {
            guard let value = op[key] as? String, !value.isEmpty else { throw EditorError("AI 的运行状态操作缺少 \(key)。") }
            return value
        }
        switch kind {
        case "select":
            try fields(["kind", "groupId", "targetId"])
            return .select(groupId: try string("groupId"), targetId: try string("targetId"))
        case "select_fastest":
            try fields(["kind", "groupId", "regions"])
            let regions = try (op["regions"] as? [String] ?? []).map { code -> Region in
                guard let region = Region(rawValue: code.uppercased()), region != .unknown else { throw EditorError("不支持的地区代码：\(code.prefix(10))") }
                return region
            }
            return .selectFastest(groupId: try string("groupId"), regions: regions)
        case "mode":
            try fields(["kind", "mode"])
            let mode = try string("mode").lowercased()
            guard modes.contains(mode) else { throw EditorError("mode 只能是 rule、global 或 direct。") }
            return .mode(mode)
        case "test":
            try fields(["kind", "groupId"])
            return .test(groupId: try string("groupId"))
        case "close_connections":
            try fields(["kind", "host"])
            let host = try string("host").lowercased()
            guard host.count <= 253, host.range(of: #"^[a-z0-9.*-]+$"#, options: .regularExpression) != nil else {
                throw EditorError("close_connections.host 必须是一个域名。")
            }
            return .closeConnections(host: host)
        default:
            throw EditorError("运行状态操作只支持 select、select_fastest、mode、test、close_connections（收到 \(kind.prefix(30))）。")
        }
    }

    /// With group and node names in place of ids; nil when an id does not name a group (or a
    /// member of that group).
    func resolved(in draft: ConfigDocument) throws -> RuntimeStep {
        func group(_ id: String) throws -> String {
            guard let target = draft.target(id: id), target.kind == .group else { throw EditorError("运行状态操作里的 \(id.prefix(30)) 不是策略组。") }
            return target.name
        }
        switch self {
        case let .select(groupId, targetId):
            let name = try group(groupId)
            guard let member = draft.target(id: targetId)?.name else { throw EditorError("运行状态操作里的 \(targetId.prefix(30)) 不存在。") }
            if let members = draft.groupMembers[name], !members.contains(member) {
                throw EditorError("“\(member)”不是“\(name)”的成员，不能选择它。请只选择该策略组 proxies 里的出口。")
            }
            return .select(group: name, node: member)
        case let .selectFastest(groupId, regions):
            return .selectFastest(group: try group(groupId), regions: regions)
        case let .mode(mode):
            return .mode(mode)
        case let .test(groupId):
            return .test(group: try group(groupId))
        case let .closeConnections(host):
            return .closeConnections(host: host)
        }
    }
}

/// A runtime action with real names, as the conversation shows and Veer runs it.
public enum RuntimeStep: Codable, Sendable, Equatable {
    case select(group: String, node: String)
    case selectFastest(group: String, regions: [Region])
    case mode(String)
    case test(group: String)
    case closeConnections(host: String)
}

/// The runtime actions of one turn and what came of them.
public struct RuntimeRun: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case waiting, running, done, failed }

    /// What turns one action back: the node or mode it replaced.
    public enum Undo: Codable, Sendable, Equatable {
        case select(group: String, node: String)
        case mode(String)
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let step: RuntimeStep
        public var state: State
        /// What happened, in words ("已切换到 🇺🇸 洛杉矶 01（86 ms）"), or why it failed.
        public var result: String?
        public var undo: Undo?

        public init(id: Int, step: RuntimeStep, state: State = .waiting, result: String? = nil, undo: Undo? = nil) {
            self.id = id
            self.step = step
            self.state = state
            self.result = result
            self.undo = undo
        }
    }

    public var items: [Item]
    public var undone: Bool

    public init(steps: [RuntimeStep]) {
        items = steps.enumerated().map { Item(id: $0.offset, step: $0.element) }
        undone = false
    }

    public var finished: Bool { items.allSatisfy { $0.state == .done || $0.state == .failed } }
    public var canUndo: Bool { finished && !undone && items.contains { $0.undo != nil } }
}

public extension RuntimeStep {
    /// One line for the conversation and the anonymized history.
    var summary: String {
        switch self {
        case let .select(group, node): "“\(group)”切换到 \(node)"
        case let .selectFastest(group, regions):
            regions.isEmpty ? "“\(group)”切换到延迟最低的节点" : "“\(group)”切换到延迟最低的\(regions.map(\.displayName).joined(separator: "、"))节点"
        case let .mode(mode): "切换到 \(mode) 模式"
        case let .test(group): "测试“\(group)”的延迟"
        case let .closeConnections(host): "断开到 \(host) 的连接"
        }
    }
}
