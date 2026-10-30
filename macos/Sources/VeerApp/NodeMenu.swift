import SwiftUI
import VeerCore
import VeerProxy

/// The members of a group as menu items, one line each. Past `flatLimit` members the nodes
/// fold into one submenu per region (with its count and best delay) so the menu fits on screen;
/// sub-groups and DIRECT stay at the top.
struct NodeMenuItems: View {
    @Environment(ProxyStore.self) private var store
    let group: ProxyStore.Group
    static let flatLimit = 12

    private struct Bucket: Identifiable {
        let code: String?
        let members: [ProxyStore.Group.Member]
        var id: String { code ?? "" }
    }

    var body: some View {
        if group.members.count <= Self.flatLimit {
            ForEach(group.members) { item($0) }
        } else {
            let top = group.members.filter { $0.isGroup || NodeMapView.builtins.contains($0.name) }
            ForEach(top) { item($0) }
            if !top.isEmpty { Divider() }
            ForEach(buckets) { bucket in
                Menu {
                    ForEach(bucket.members) { item($0) }
                } label: {
                    // A submenu's title shows no icon, so the mark is part of the text.
                    Text(verbatim: (bucket.members.contains { $0.name == group.now } ? "✓ " : "") + title(bucket))
                }
            }
        }
    }

    /// Nodes by region, the regions with the most nodes first; unknown ones last.
    private var buckets: [Bucket] {
        let nodes = group.members.filter { !$0.isGroup && !NodeMapView.builtins.contains($0.name) }
        let grouped = Dictionary(grouping: nodes) { store.region(of: $0.name) }
        return grouped.map { Bucket(code: $0.key, members: $0.value) }
            .sorted { a, b in
                if (a.code == nil) != (b.code == nil) { return b.code == nil }
                return (a.members.count, b.id) > (b.members.count, a.id)
            }
    }

    private func title(_ bucket: Bucket) -> String {
        let place = bucket.code.flatMap(NodeLocator.place)
        let name = place.map { "\($0.flag) \($0.name)" } ?? String(localized: "其他")
        let best = bucket.members.map(\.delay).reduce(nil, NodeMapView.better)
        return "\(name) · \(bucket.members.count) · \(Format.delay(best))"
    }

    @ViewBuilder private func item(_ member: ProxyStore.Group.Member) -> some View {
        let text = "\(member.name)    \(Format.delay(member.delay))"
        Button { store.select(member.name, in: group.name) } label: {
            if member.name == group.now { Label(text, systemImage: "checkmark") } else { Text(verbatim: text) }
        }
    }
}
