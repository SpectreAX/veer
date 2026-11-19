import Foundation

/// A domain with a rule of its own pointing at a select group made for it, which someone now wants
/// direct. Replacing the rule leaves the group behind with nothing using it, and they lose the
/// choice they set it up for, so the group gets a DIRECT option instead, or they are asked.
public enum DedicatedGroupRoute {
    public struct Conflict: Sendable, Equatable {
        public let group: String
        public let match: String

        public init(group: String, match: String) {
            self.group = group
            self.match = match
        }
    }

    public enum Choice: Sendable, Equatable {
        /// Add DIRECT to the group if it lacks it, and switch to it.
        case useDirect(group: String)
        /// Send the domain direct, replacing its rule.
        case replaceRule(match: String, matchType: String)
    }

    /// The first thing it finds, when every operation sends a domain direct away from one such group.
    /// A plan that also does other things is not stopped: an answer here could not carry them along.
    public static func conflict(in plan: EditPlan, draft: ConfigDocument) -> Conflict? {
        var found: Conflict?
        for operation in plan.operations {
            guard case let .route(matchType, match, targetId) = operation, ["DOMAIN", "DOMAIN-SUFFIX"].contains(matchType),
                  draft.target(id: targetId)?.name == "DIRECT", let group = ownGroup(of: match, in: draft),
                  found == nil || found?.group == group else { return nil }
            found = found ?? Conflict(group: group, match: match)
        }
        return found
    }

    /// The select group whose own rule catches `domain`, if the domain has one.
    static func ownGroup(of domain: String, in draft: ConfigDocument) -> String? {
        // Checked as an HTTPS connection, like the Agent's domain checks; no geodata is needed for a domain's own rule.
        guard let query = RouteQuery(domain, port: 443, network: .tcp),
              let rule = RouteTracer.trace(query, rules: draft.rules, data: RouteData()).hit?.rule, let parts = RuleParts.parse(rule),
              ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].contains(parts.type),
              let group = draft.target(named: parts.target), group.kind == .group, group.type == "select",
              GroupPurpose.isDedicated(group.name) else { return nil }
        return group.name
    }

    public static func question(for conflict: Conflict) -> String {
        String(localized: "\(conflict.match) 现在走它专用的策略组“\(conflict.group)”。你想怎么改成直连？")
    }

    public static func options(for conflict: Conflict) -> [ClarifyOption] {
        [ClarifyOption(label: String(localized: "在策略组里加入直连"), prompt: useDirectPrompt(group: conflict.group)),
         ClarifyOption(label: String(localized: "替换这条规则"), prompt: replacePrompt(match: conflict.match, group: conflict.group))]
    }

    static func useDirectPrompt(group: String) -> String {
        String(localized: "在策略组“\(group)”里加入直连并切换过去")
    }

    /// The domain comes first, up to a space, so `choice` can read it back in any language.
    static func replacePrompt(match: String, group: String) -> String {
        String(localized: "\(match) 走直连，替换策略组“\(group)”的这条规则")
    }

    /// Which option an instruction is, word for word; nil for anything else.
    public static func choice(for prompt: String, in draft: ConfigDocument) -> Choice? {
        for target in draft.targets where target.kind == .group && prompt == useDirectPrompt(group: target.name) {
            return .useDirect(group: target.name)
        }
        guard let match = prompt.split(separator: " ").first.map(String.init), let group = ownGroup(of: match, in: draft),
              prompt == replacePrompt(match: match, group: group) else { return nil }
        let own = draft.rules.compactMap(RuleParts.parse).first { $0.payload == match && $0.target == group }
        return .replaceRule(match: match, matchType: own.map(\.type).flatMap { $0 == "DOMAIN" ? $0 : nil } ?? "DOMAIN-SUFFIX")
    }

    /// The group's members with DIRECT added, as target ids; nil when it already has it.
    public static func membersAddingDirect(to group: String, in draft: ConfigDocument) -> [String]? {
        let members = draft.groupMembers[group] ?? []
        guard !members.contains("DIRECT"), let direct = draft.target(named: "DIRECT") else { return nil }
        return members.compactMap { draft.target(named: $0)?.id } + [direct.id]
    }

    /// Switch only after the corresponding member edit was accepted, including full-permission plans.
    public static func groupToSwitch(after prompt: String, in draft: ConfigDocument, plan: EditPlan, accepted: Set<Int>, mode: ExecutionMode) -> String? {
        guard plan.operations.count == 1, accepted.contains(0),
              case let .groupMembers(id, members) = plan.operations[0], let group = draft.target(id: id),
              members == membersAddingDirect(to: group.name, in: draft) else { return nil }
        if case .useDirect(group.name) = choice(for: prompt, in: draft) { return group.name }
        return mode == .full && GroupPurpose.isDedicated(group.name) ? group.name : nil
    }
}
