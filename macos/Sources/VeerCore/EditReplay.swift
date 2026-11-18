import Foundation

/// Re-applies the edits written into a session's draft to new configuration text, such as a
/// refreshed subscription. A plan names exits by ids that only hold for the draft it was made
/// against, so each operation is translated through exit names before it is applied again.
public enum EditReplay {
    /// The accepted operations of one written proposal, with the draft they were written onto.
    public struct Edit: Sendable {
        public let id: UUID
        public let prompt: String
        public let plan: EditPlan
        public let accepted: Set<Int>
        public let items: [ChangeItem]
        public let base: String

        public init(id: UUID, prompt: String, plan: EditPlan, accepted: Set<Int>, items: [ChangeItem], base: String) {
            self.id = id
            self.prompt = prompt
            self.plan = plan
            self.accepted = accepted
            self.items = items
            self.base = base
        }
    }

    public enum Outcome: Sendable, Equatable, Codable {
        case applied
        /// Applied, with a difference the user should know about.
        case adjusted(String)
        /// Nothing to do: the new text already reads this way.
        case unchanged(String)
        /// Not applied, and why.
        case conflict(String)
    }

    public struct ItemResult: Sendable, Identifiable, Equatable, Codable {
        public var id: Int { item.id }
        /// The change as it was first written.
        public let item: ChangeItem
        public let outcome: Outcome
    }

    public struct EditResult: Sendable, Identifiable, Equatable, Codable {
        public let id: UUID
        public let prompt: String
        public let items: [ItemResult]
    }

    public struct Result: Sendable, Equatable, Codable {
        public let text: String
        public let edits: [EditResult]

        public var appliedCount: Int { count { if case .applied = $0 { true } else if case .adjusted = $0 { true } else { false } } }
        public var unchangedCount: Int { count { if case .unchanged = $0 { true } else { false } } }
        public var conflictCount: Int { count { if case .conflict = $0 { true } else { false } } }

        private func count(_ matches: (Outcome) -> Bool) -> Int {
            edits.reduce(0) { $0 + $1.items.filter { matches($0.outcome) }.count }
        }
    }

    /// The edits in a session's draft, oldest first: proposals that were written and not undone.
    public static func edits(of session: Session) -> [Edit] {
        session.turns.compactMap { turn in
            guard let proposal = turn.proposal, proposal.status == .written else { return nil }
            return Edit(id: turn.id, prompt: turn.prompt, plan: proposal.plan, accepted: proposal.accepted,
                        items: proposal.items, base: proposal.writtenFrom ?? proposal.baseDraft)
        }
    }

    /// Applies `edits` to `text` in order. Each new group, with the changes that point to it, is
    /// applied as one step; every other operation on its own, so one conflict costs only itself.
    public static func replay(_ edits: [Edit], onto text: String, regionOverrides: [String: Region] = [:]) -> Result {
        var current = text
        var results: [EditResult] = []
        // Groups this replay created under another name, because the new text already has one.
        var renamed: [String: String] = [:]
        var verification: [String: RuleSetVerification] = [:]
        for edit in edits {
            for item in edit.items { if let provider = item.provider { verification[provider.url] = provider.verification } }
        }

        for edit in edits {
            let origin = try? ConfigDocument.parse(edit.base)
            var outcomes: [Int: Outcome] = [:]
            for bundle in bundles(of: edit) {
                guard let document = try? ConfigDocument.parse(current) else {
                    for index in bundle { outcomes[index] = .conflict(String(localized: "新内容无法解析。")) }
                    continue
                }
                var operations: [EditPlan.Operation] = []
                var positions: [Int] = []
                var notes: [Int: String] = [:]
                var failure: String?
                for index in bundle {
                    switch translate(edit.plan.operations[index], item: edit.items.first { $0.id == index },
                                     origin: origin, into: document, renamed: renamed, newGroupIDs: newGroupIDs(in: edit.plan)) {
                    case .operation(let operation, let note):
                        operations.append(operation)
                        positions.append(index)
                        if let note { notes[index] = note }
                    case .skip(let reason):
                        outcomes[index] = .unchanged(reason)
                    case .fail(let reason):
                        failure = failure ?? reason
                        outcomes[index] = .conflict(reason)
                    }
                }
                if let failure {
                    // A group and the changes pointing to it stand or fall together.
                    for index in positions { outcomes[index] = .conflict(failure) }
                    continue
                }
                guard !operations.isEmpty else { continue }
                do {
                    let result = try PlanApplier.apply(EditPlan(operations: operations), to: document,
                                                       regions: regions(for: document, overrides: regionOverrides), verification: verification)
                    for (offset, index) in positions.enumerated() {
                        if !result.changed {
                            outcomes[index] = .unchanged(String(localized: "新内容里已经是这样了。"))
                        } else if let note = notes[index] {
                            outcomes[index] = .adjusted(note)
                        } else {
                            outcomes[index] = .applied
                        }
                        if case .group = operations[offset], let original = edit.items.first(where: { $0.id == index })?.group?.name,
                           let created = result.items.first(where: { $0.id == offset })?.group?.name, created != original {
                            renamed[original] = created
                            outcomes[index] = .adjusted(String(localized: "新内容里已有同名出口，这次新建为“\(created)”。"))
                        }
                    }
                    current = result.candidate
                } catch {
                    let reason = (error as? EditorError)?.message ?? String(localized: "无法应用。")
                    for index in positions { outcomes[index] = .conflict(reason) }
                }
            }
            let items = edit.items.filter { edit.accepted.contains($0.id) }.sorted { $0.id < $1.id }
                .map { ItemResult(item: $0, outcome: outcomes[$0.id] ?? .conflict(String(localized: "无法应用。"))) }
            results.append(EditResult(id: edit.id, prompt: edit.prompt, items: items))
        }
        return Result(text: current, edits: results)
    }

    // MARK: Translation

    private struct TranslationFailure: Error { let reason: String }

    private enum Translation {
        case operation(EditPlan.Operation, note: String?)
        case skip(String)
        case fail(String)
    }

    /// Accepted operations grouped into the steps they are applied in, in plan order.
    static func bundles(of edit: Edit) -> [[Int]] {
        let accepted = edit.plan.operations.indices.filter { edit.accepted.contains($0) }
        var bundles: [[Int]] = []
        var placed = Set<Int>()
        for index in accepted where !placed.contains(index) {
            if case .group(let spec) = edit.plan.operations[index] {
                let dependents = accepted.filter { other in
                    switch edit.plan.operations[other] {
                    case .route(_, _, let target), .ruleSet(_, let target): target == spec.id
                    default: false
                    }
                }
                bundles.append([index] + dependents)
                placed.formUnion([index] + dependents)
            } else if !isDependent(edit.plan.operations[index], in: edit.plan) {
                bundles.append([index])
                placed.insert(index)
            }
        }
        return bundles
    }

    private static func newGroupIDs(in plan: EditPlan) -> Set<String> {
        Set(plan.operations.compactMap { if case .group(let spec) = $0 { spec.id } else { nil } })
    }

    private static func isDependent(_ operation: EditPlan.Operation, in plan: EditPlan) -> Bool {
        switch operation {
        case .route(_, _, let target), .ruleSet(_, let target): newGroupIDs(in: plan).contains(target)
        default: false
        }
    }

    private static func translate(_ operation: EditPlan.Operation, item: ChangeItem?, origin: ConfigDocument?, into document: ConfigDocument,
                                  renamed: [String: String], newGroupIDs: Set<String>) -> Translation {
        func target(_ id: String) -> Swift.Result<String, TranslationFailure> {
            if newGroupIDs.contains(id) { return .success(id) }
            guard let original = origin?.target(id: id)?.name ?? item?.targetName else { return .failure(.init(reason: String(localized: "找不到这项修改原来的出口。"))) }
            let name = renamed[original] ?? original
            guard let found = document.target(named: name) else { return .failure(.init(reason: String(localized: "出口“\(name)”不在新内容中。"))) }
            return .success(found.id)
        }
        switch operation {
        case let .route(matchType, match, targetID):
            switch target(targetID) {
            case .success(let id): return .operation(.route(matchType: matchType, match: match, targetId: id), note: nil)
            case .failure(let failure): return .fail(failure.reason)
            }
        case let .ruleSet(reference, targetID):
            switch target(targetID) {
            case .success(let id): return .operation(.ruleSet(reference, targetId: id), note: nil)
            case .failure(let failure): return .fail(failure.reason)
            }
        case let .removeRule(matchType, match):
            let prefix = "\(matchType),\(match),".lowercased()
            guard document.rules.contains(where: { $0.lowercased().hasPrefix(prefix) }) else { return .skip(String(localized: "新内容里已经没有这条规则。")) }
            return .operation(operation, note: nil)
        case let .removeRuleAt(_, rule):
            guard let index = document.rules.firstIndex(of: rule) else { return .skip(String(localized: "新内容里已经没有这条规则。")) }
            return .operation(.removeRuleAt(index: index, rule: rule), note: nil)
        case let .removeProvider(key):
            guard document.providers.contains(where: { $0.key == key }) else { return .skip(String(localized: "新内容里已经没有规则集 \(key)。")) }
            return .operation(operation, note: nil)
        case let .addMatch(targetID):
            guard !document.rules.contains(where: { RuleParts.parse($0)?.type == "MATCH" }) else { return .skip(String(localized: "新内容里已经有 MATCH 规则。")) }
            switch target(targetID) {
            case .success(let id): return .operation(.addMatch(targetId: id), note: nil)
            case .failure(let failure): return .fail(failure.reason)
            }
        case let .moveRule(_, rule, _, beforeRule):
            guard let from = document.rules.firstIndex(of: rule) else { return .skip(String(localized: "新内容里已经没有这条规则。")) }
            guard let before = document.rules.firstIndex(of: beforeRule) else { return .fail(String(localized: "新内容里已经没有 \(beforeRule) 这条规则。")) }
            guard from > before else { return .skip(String(localized: "新内容里它已经在 \(beforeRule) 之前。")) }
            return .operation(.moveRule(index: from, rule: rule, before: before, beforeRule: beforeRule), note: nil)
        case let .groupMembers(groupID, memberIDs):
            let group: String
            switch target(groupID) {
            case .success(let id): group = id
            case .failure(let failure): return .fail(failure.reason)
            }
            var members: [String] = []
            var missing: [String] = []
            for id in memberIDs {
                switch target(id) {
                case .success(let id): members.append(id)
                case .failure: missing.append(origin?.target(id: id)?.name ?? id)
                }
            }
            if members.isEmpty, !memberIDs.isEmpty { return .fail(String(localized: "策略组“\(item?.subject ?? "")”的成员都不在新内容中。")) }
            let note = missing.isEmpty ? nil : String(localized: "成员 \(missing.map { "“\($0)”" }.joined(separator: "、")) 不在新内容中，已略过。")
            return .operation(.groupMembers(targetId: group, members: members), note: note)
        case let .group(spec):
            var members: [String] = []
            var missing: [String] = []
            for id in spec.members {
                switch target(id) {
                case .success(let id): members.append(id)
                case .failure:
                    missing.append(origin?.target(id: id)?.name ?? id)
                }
            }
            if members.isEmpty, !spec.members.isEmpty, spec.regions.isEmpty, spec.excludeRegions.isEmpty {
                return .fail(String(localized: "新策略组“\(spec.name)”的成员都不在新内容中。"))
            }
            let group = EditPlan.NewGroup(id: spec.id, name: spec.name, type: spec.type, regions: spec.regions,
                                          members: members, excludeRegions: spec.excludeRegions)
            let note = missing.isEmpty ? nil : String(localized: "成员 \(missing.map { "“\($0)”" }.joined(separator: "、")) 不在新内容中，已略过。")
            return .operation(.group(group), note: note)
        }
    }

    private static func regions(for document: ConfigDocument, overrides: [String: Region]) -> [String: Region] {
        var result: [String: Region] = [:]
        for target in document.targets where target.kind != .builtin {
            result[target.name] = overrides[target.name] ?? Region.infer(from: target.name)
        }
        return result
    }
}
