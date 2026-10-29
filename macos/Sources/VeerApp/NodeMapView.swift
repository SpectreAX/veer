import SwiftUI
import VeerCore
import VeerProxy

/// Nodes on a world map: one dot per region, colored by the region's best delay. Choosing a dot
/// lists its nodes; choosing a node uses it in the main group when that group has it.
struct NodeMapView: View {
    @Environment(ProxyStore.self) private var store
    @State private var selected: String?

    /// Every real node in the running config with its best known delay, by region code; nodes
    /// whose region is unknown are under nil.
    private var regions: [String?: [MapNode]] {
        var best: [String: Int?] = [:]
        for group in store.groups {
            // Subscriptions list their traffic and expiry as fake nodes; they exit nowhere.
            for member in group.members where !member.isGroup && !Self.builtins.contains(member.name) && !NodeCleanup.isInfoNode(member.name) {
                let known = best[member.name] ?? nil
                best[member.name] = Self.better(known, member.delay)
            }
        }
        return Dictionary(grouping: best.map { MapNode(name: $0.key, delay: $0.value) }.sorted { $0.name < $1.name }) {
            store.region(of: $0.name)
        }
    }

    static let builtins: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

    /// A working delay beats a failed one, a lower one beats a higher.
    static func better(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, _): b
        case (_, nil): a
        case (0?, _): b
        case (_, 0?): a
        case let (x?, y?): min(x, y)
        }
    }

    var body: some View {
        let regions = regions
        HStack(alignment: .top, spacing: Spacing.lg) {
            WorldMap(regions: regions, selected: $selected)
                .frame(maxWidth: .infinity)
            RegionList(regions: regions, selected: $selected)
                .frame(width: 280)
        }
        .padding(Spacing.xl)
    }
}

struct MapNode: Identifiable, Hashable {
    let name: String
    let delay: Int?
    var id: String { name }
}

/// Land outlines from Natural Earth (public domain) in an equirectangular projection, with a dot
/// for each region that has nodes.
private struct WorldMap: View {
    let regions: [String?: [MapNode]]
    @Binding var selected: String?

    /// Latitudes shown: Antarctica and the far north add nothing here.
    private static let north = 84.0, south = -58.0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for ring in Self.land {
                        var path = Path()
                        for (index, point) in ring.enumerated() {
                            let p = Self.project(longitude: point[0], latitude: point[1], in: size)
                            index == 0 ? path.move(to: p) : path.addLine(to: p)
                        }
                        path.closeSubpath()
                        context.fill(path, with: .color(Color.secondary.opacity(0.18)))
                    }
                }
                ForEach(regions.keys.compactMap { $0 }.sorted(), id: \.self) { code in
                    if let place = NodeLocator.place(code), let nodes = regions[code] {
                        dot(place: place, nodes: nodes)
                            .position(Self.project(longitude: place.longitude, latitude: place.latitude, in: size))
                    }
                }
            }
        }
        .aspectRatio(360 / (Self.north - Self.south), contentMode: .fit)
        .padding(Spacing.md)
        .panel()
    }

    private func dot(place: NodeLocator.Place, nodes: [MapNode]) -> some View {
        let best = nodes.map(\.delay).reduce(nil, NodeMapView.better)
        let isSelected = selected == place.code
        return Button { selected = isSelected ? nil : place.code } label: {
            Circle()
                .fill(Format.delayKind(best).color)
                .frame(width: isSelected ? 16 : 11, height: isSelected ? 16 : 11)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: isSelected ? 2.5 : 1.5))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "\(place.flag) \(place.name)：\(nodes.count) 个节点，最低延迟 \(Format.delay(best))"))
        .accessibilityLabel(String(localized: "\(place.name)，\(nodes.count) 个节点，最低延迟 \(Format.delay(best))"))
        .animation(Motion.standard, value: isSelected)
    }

    static func project(longitude: Double, latitude: Double, in size: CGSize) -> CGPoint {
        let clamped = min(max(latitude, south), north)
        return CGPoint(x: (longitude + 180) / 360 * size.width, y: (north - clamped) / (north - south) * size.height)
    }

    /// Rings of [longitude, latitude], loaded once from the app bundle.
    static let land: [[[Double]]] = {
        guard let url = Bundle.main.url(forResource: "land-110m", withExtension: "json", subdirectory: "Map")
                ?? Bundle.main.url(forResource: "land-110m", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([[[Double]]].self, from: data)) ?? []
    }()
}

/// The regions by node count, or the chosen region's nodes. Nodes the names say nothing about
/// come last, with a hint that they can be marked by hand.
private struct RegionList: View {
    @Environment(ProxyStore.self) private var store
    let regions: [String?: [MapNode]]
    @Binding var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let code = selected, let place = NodeLocator.place(code) {
                HStack {
                    Button { selected = nil } label: { Label("全部地区", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                Text(verbatim: "\(place.flag) \(place.name)").font(.headline)
                nodeList(regions[code] ?? [])
            } else {
                Text("地区").font(.headline)
                ScrollView {
                    VStack(spacing: Spacing.xxs) {
                        ForEach(sortedCodes, id: \.self) { code in
                            if let place = NodeLocator.place(code), let nodes = regions[code] {
                                Button { selected = code } label: {
                                    HStack {
                                        Text(verbatim: "\(place.flag) \(place.name)").lineLimit(1)
                                        Spacer()
                                        Text(verbatim: "\(nodes.count)").foregroundStyle(.secondary).monospacedDigit()
                                        let best = nodes.map(\.delay).reduce(nil, NodeMapView.better)
                                        Text(Format.delay(best)).font(.caption.monospacedDigit()).foregroundStyle(Format.delayKind(best).color)
                                            .frame(width: 56, alignment: .trailing)
                                    }
                                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let unknown = regions[nil], !unknown.isEmpty {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("未识别 \(unknown.count) 个").font(.subheadline.weight(.semibold))
                                Text("在代理页的节点上右键，可以手动标记地区。").font(.caption).foregroundStyle(.secondary)
                                ForEach(unknown) { Text($0.name).font(.caption).lineLimit(1).truncationMode(.middle) }
                            }
                            .padding(Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
    }

    private var sortedCodes: [String] {
        regions.keys.compactMap { $0 }.sorted { (regions[$0]?.count ?? 0, $1) > (regions[$1]?.count ?? 0, $0) }
    }

    private func nodeList(_ nodes: [MapNode]) -> some View {
        let main = store.mainGroup
        return ScrollView {
            VStack(spacing: Spacing.xxs) {
                ForEach(nodes) { node in
                    let usable = main.map { $0.isSelectable && $0.members.contains { $0.name == node.name } } ?? false
                    Button { if let main, usable { store.select(node.name, in: main.name) } } label: {
                        HStack {
                            Image(systemName: main?.now == node.name ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(main?.now == node.name ? Color.veerAccent : Color.secondary)
                                .opacity(usable ? 1 : 0)
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.delay(node.delay)).font(.caption.monospacedDigit()).foregroundStyle(Format.delayKind(node.delay).color)
                        }
                        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!usable)
                    .help(usable ? String(localized: "在“\(main?.name ?? "")”中使用这个节点") : node.name)
                }
            }
        }
    }
}
