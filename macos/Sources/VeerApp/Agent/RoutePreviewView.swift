import SwiftUI
import VeerCore
import VeerProxy
import VeerUI

extension AgentStore {
    /// Where the turn's domains go now and after its proposal, decided on this Mac with the rule sets
    /// and geodata Route Test reads. nil when the change names no domain to show.
    func routePreview(turn: Turn, proposal: Turn.Proposal) async -> RoutePreview? {
        let home = proxy.paths.core, geo = GeoDataStore.shared
        let items = proposal.items.filter { proposal.accepted.contains($0.id) }
        let named = (turn.lookups?.domains.map(\.domain) ?? []) + (turn.checks?.map(\.domain) ?? [])
        let base = proposal.baseDraft, candidate = proposal.candidate
        return await Task.detached(priority: .utility) {
            // Geodata is read once; the candidate only brings its own rules and rule sets.
            let before = await RouteTestSource.load(config: base, home: home, fallback: geo)
            let after = RouteTestSource.withoutGeodata(config: candidate, home: home)
            var afterData = before.data
            afterData.ruleSets = after.data.ruleSets
            let domains = RoutePreview.domains(items: items, named: named, geosite: before.data.geosite)
            guard !domains.isEmpty else { return nil }
            return RoutePreview.make(domains: domains, before: before.rules, beforeData: before.data, after: after.rules, afterData: afterData)
        }.value
    }

    /// An exit as the card names it: DIRECT and REJECT in words, a node or group with its region.
    func exitTitle(_ name: String?) -> String {
        guard let name, name != "DIRECT" else { return String(localized: "直连") }
        if name == "REJECT" { return String(localized: "拦截") }
        let region = regions[name] ?? .unknown
        return region == .unknown ? name : String(localized: "\(name)（\(region.displayName)）")
    }
}

/// Where the proposal's domains go now and after it is applied. Expanded, since it is how the user
/// checks the change before applying it.
struct RoutePreviewView: View {
    let preview: RoutePreview
    /// Worked out again after the selection changed; the rows shown are the previous ones.
    var updating = false
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(preview.rows) { RoutePreviewRow(row: $0) }
                Text(String(localized: "在本机按 TCP 443 的 HTTPS 连接判断，不查询 DNS。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.small))
        } label: {
            HStack(spacing: Spacing.sm) {
                Label(String(localized: "应用后的走向"), systemImage: "arrow.triangle.branch").font(.callout)
                if updating { ProgressView().controlSize(.mini).accessibilityLabel(String(localized: "正在更新")) }
            }
        }
    }
}

struct RoutePreviewRow: View {
    @Environment(AgentStore.self) private var store
    let row: RoutePreview.Row

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(row.domain).font(Typography.codeSmall).textSelection(.enabled)
            Text(route).font(.caption).fontWeight(row.changed ? .medium : .regular)
            Group {
                if row.afterCertain {
                    Text(rule).font(.caption).foregroundStyle(.secondary)
                } else {
                    // A status colour comes with its symbol (TOKENS.md), not as coloured text alone.
                    StatusBadge(kind: .warning, text: rule, compact: true)
                }
            }
            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Where it goes now, marked when an earlier rule Veer cannot decide might send it elsewhere.
    private var before: String {
        let title = store.exitTitle(row.before?.target)
        return row.beforeCertain ? title : String(localized: "\(title)（可能）")
    }

    private var route: String {
        row.changed ? "\(before) → \(store.exitTitle(row.after?.target))" : String(localized: "\(store.exitTitle(row.after?.target))，不变")
    }

    /// The rule that decides it after the change, and whether an earlier rule might come first.
    private var rule: String {
        guard let hit = row.after else { return String(localized: "没有规则匹配，内核会直连。") }
        return row.afterCertain ? String(localized: "命中第 \(hit.index + 1) 条 \(hit.rule)") : String(localized: "可能命中第 \(hit.index + 1) 条 \(hit.rule)")
    }

    private var accessibilityText: String {
        let after = store.exitTitle(row.after?.target)
        return row.changed
            ? String(localized: "\(row.domain)：从\(before)改为\(after)。\(rule)")
            : String(localized: "\(row.domain)：仍走\(after)。\(rule)")
    }
}
