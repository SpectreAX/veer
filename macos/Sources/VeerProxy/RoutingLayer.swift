import Foundation
import VeerCore
import Yams

/// "My routing": what the user changed on top of a profile, kept apart from it so a refreshed
/// subscription keeps the changes. The profile text stays exactly as downloaded.
public struct RoutingLayer: Codable, Sendable, Equatable {
    /// One written change: the accepted operations of a plan, with the text they were made on.
    public struct Edit: Codable, Sendable, Equatable, Identifiable {
        public enum Source: String, Codable, Sendable {
            case agent, manual, healthCheck, template
        }

        public let id: UUID
        public let createdAt: Date
        public let source: Source
        /// The user's words, or what a manual change did.
        public let prompt: String
        public let plan: EditPlan
        public let accepted: Set<Int>
        public let items: [ChangeItem]
        /// The text the plan was made against; its target ids hold only there.
        public let base: String
        /// Off keeps the change on record without applying it (an undone change).
        public var enabled: Bool

        public init(id: UUID = UUID(), createdAt: Date = .now, source: Source, prompt: String, plan: EditPlan,
                    accepted: Set<Int>, items: [ChangeItem], base: String, enabled: Bool = true) {
            self.id = id
            self.createdAt = createdAt
            self.source = source
            self.prompt = prompt
            self.plan = plan
            self.accepted = accepted
            self.items = items
            self.base = base
            self.enabled = enabled
        }

        var replayable: EditReplay.Edit {
            EditReplay.Edit(id: id, prompt: prompt, plan: plan, accepted: accepted, items: items, base: base)
        }
    }

    public var edits: [Edit]
    /// Nodes the user unchecked, by name; names survive a subscription refresh, ids do not.
    public var excludedNodes: Set<String>
    /// The built-in rule template in use; nil keeps the profile's own rules.
    public var template: String?
    /// Regions the user set by hand for nodes whose names say nothing (ISO codes, by node name).
    public var regionMarks: [String: String]

    public init(edits: [Edit] = [], excludedNodes: Set<String> = [], template: String? = nil, regionMarks: [String: String] = [:]) {
        self.edits = edits
        self.excludedNodes = excludedNodes
        self.template = template
        self.regionMarks = regionMarks
    }

    /// Layers saved before a field existed decode with it empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        edits = try container.decodeIfPresent([Edit].self, forKey: .edits) ?? []
        excludedNodes = try container.decodeIfPresent(Set<String>.self, forKey: .excludedNodes) ?? []
        template = try container.decodeIfPresent(String.self, forKey: .template)
        regionMarks = try container.decodeIfPresent([String: String].self, forKey: .regionMarks) ?? [:]
    }

    public var isEmpty: Bool { edits.isEmpty && excludedNodes.isEmpty && template == nil && regionMarks.isEmpty }

    /// Where a node exits: the user's mark, else what its name says.
    public func region(of node: String) -> String? { regionMarks[node] ?? NodeLocator.locate(node) }

    /// Marks as the AI's regions, for replaying edits that pick nodes by region.
    var regionOverrides: [String: Region] { regionMarks.compactMapValues(Region.init(rawValue:)) }
}

/// The config the core runs and an export writes: the profile with the layer applied.
public struct EffectiveConfig: Sendable, Equatable, Codable {
    public let text: String
    /// What happened to each enabled edit; nil when there were none.
    public let replay: EditReplay.Result?
    /// Groups left without members once excluded nodes were taken out; they fall back to DIRECT.
    public let emptiedGroups: [String]
    /// Excluded nodes kept because a rule sends traffic to them by name.
    public let keptNodes: [String]

    public var conflictCount: Int { replay?.conflictCount ?? 0 }
}

public extension RoutingLayer {
    /// Puts the template's groups and rules in (when one is chosen), replays the enabled edits
    /// onto that, then takes the excluded nodes out.
    func apply(to profile: String) throws -> EffectiveConfig {
        let base = try template.map { try RuleTemplate.apply($0, to: profile, regionMarks: regionMarks) } ?? profile
        let active = edits.filter(\.enabled).map(\.replayable)
        let replay = active.isEmpty ? nil : EditReplay.replay(active, onto: base, regionOverrides: regionOverrides)
        let replayed = replay?.text ?? base
        guard !excludedNodes.isEmpty else {
            return EffectiveConfig(text: replayed, replay: replay, emptiedGroups: [], keptNodes: [])
        }
        let (text, emptied, kept) = try Self.removing(excludedNodes, from: replayed)
        return EffectiveConfig(text: text, replay: replay, emptiedGroups: emptied, keptNodes: kept)
    }

    /// Takes `names` out of `proxies` and every group. A node a rule names stays, since the core
    /// would refuse a rule whose policy is gone; a group left empty gets DIRECT.
    internal static func removing(_ names: Set<String>, from text: String) throws -> (String, emptied: [String], kept: [String]) {
        guard let root = try Yams.compose(yaml: text), case .mapping(var mapping) = root else {
            throw EditorError(String(localized: "配置文件不是有效的 Mihomo 配置：顶层应该是键值对。"))
        }
        var ruleTargets: Set<String> = []
        if case .sequence(let rules)? = mapping[Node("rules")] {
            for rule in rules { if let target = rule.string.flatMap(RuleParts.parse)?.target { ruleTargets.insert(target) } }
        }
        let kept = names.filter(ruleTargets.contains).sorted()
        let removed = names.subtracting(kept)
        guard !removed.isEmpty else { return (text, [], kept) }

        if case .sequence(var proxies)? = mapping[Node("proxies")] {
            proxies = Node.Sequence(proxies.filter { node in
                guard case .mapping(let proxy) = node, let name = proxy[Node("name")]?.string else { return true }
                return !removed.contains(name)
            }, proxies.tag, proxies.style)
            mapping[Node("proxies")] = .sequence(proxies)
        }

        var emptied: [String] = []
        if case .sequence(var groups)? = mapping[Node("proxy-groups")] {
            for index in groups.indices {
                guard case .mapping(var group) = groups[index], case .sequence(let members)? = group[Node("proxies")] else { continue }
                let left = members.filter { !removed.contains($0.string ?? "") }
                guard left.count != members.count else { continue }
                // A group that also takes nodes from providers or include-all still has some.
                let fedElsewhere = group[Node("use")] != nil || group[Node("include-all")]?.bool == true
                    || group[Node("include-all-proxies")]?.bool == true
                if left.isEmpty, !fedElsewhere {
                    group[Node("proxies")] = Node([Node("DIRECT")])
                    emptied.append(group[Node("name")]?.string ?? "")
                } else {
                    group[Node("proxies")] = .sequence(Node.Sequence(Array(left), members.tag, members.style))
                }
                groups[index] = .mapping(group)
            }
            mapping[Node("proxy-groups")] = .sequence(groups)
        }
        return (ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true)), emptied, kept)
    }
}

/// One layer per profile in `routing/<id>.json`.
public final class RoutingStore: @unchecked Sendable {
    public let paths: VeerPaths
    private let lock = NSLock()

    public init(paths: VeerPaths) { self.paths = paths }

    /// The profile's layer; an empty one when it has none yet.
    public func load(_ id: UUID) -> RoutingLayer {
        lock.withLock {
            guard let data = try? Data(contentsOf: file(id)) else { return RoutingLayer() }
            return (try? Self.decoder.decode(RoutingLayer.self, from: data)) ?? RoutingLayer()
        }
    }

    /// The layer with the bytes it was read from, which `EffectiveConfigCache` keys on; nil when
    /// the profile has no layer.
    public func loadWithData(_ id: UUID) -> (layer: RoutingLayer, data: Data)? {
        lock.withLock {
            guard let data = try? Data(contentsOf: file(id)), let layer = try? Self.decoder.decode(RoutingLayer.self, from: data) else { return nil }
            return (layer, data)
        }
    }

    public func save(_ layer: RoutingLayer, for id: UUID) throws {
        try paths.prepare()
        try lock.withLock {
            if layer.isEmpty {
                try? FileManager.default.removeItem(at: file(id))
                return
            }
            try Self.encoder.encode(layer).write(to: file(id), options: .atomic)
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock { try? FileManager.default.removeItem(at: file(id)) }
    }

    private func file(_ id: UUID) -> URL { paths.routing.appendingPathComponent("\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
