import SwiftUI
import VeerCore
import VeerProxy

/// Nodes on a world map, with the regions below it and the chosen region's nodes below those.
/// A dot's color is the region's best delay and its number the region's nodes; choosing a node
/// uses it in the main group when that group has it.
struct NodeMapView: View {
    @Environment(ProxyStore.self) private var store
    /// The toolbar's search: nodes whose name or region contains it.
    var query = ""
    /// A region code or `unknownRegion`; until the user chooses, the region of the node in use.
    @State private var chosen: String?

    static let unknownRegion = "unknown"

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
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = Dictionary(grouping: best.map { MapNode(name: $0.key, delay: $0.value) }.sorted { $0.name < $1.name }) {
            store.region(of: $0.name)
        }
        guard !text.isEmpty else { return all }
        var shown: [String?: [MapNode]] = [:]
        for (code, nodes) in all {
            let placeMatches = code.flatMap(NodeLocator.place)?.name.lowercased().contains(text) ?? false
            let matching = placeMatches ? nodes : nodes.filter { $0.name.lowercased().contains(text) }
            if !matching.isEmpty { shown[code] = matching }
        }
        return shown
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
        let selected = selection(in: regions)
        // The same scroll view whatever the search finds: taking it away for an empty state would
        // take the keyboard focus out of the search field, in the middle of typing.
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                MapCard(regions: regions, selected: selected) { chosen = $0 }
                if regions.isEmpty {
                    Text(String(localized: "没有匹配“\(query)”的节点")).font(.callout).foregroundStyle(.secondary)
                } else {
                    RegionGrid(regions: regions, selected: selected) { chosen = $0 }
                    if let selected {
                        RegionNodes(code: selected, nodes: nodes(of: selected, in: regions))
                    } else {
                        Text("选择一个地区查看节点").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Spacing.xl)
        }
    }

    /// What the user chose, else the region of the node in use, if it is still listed.
    private func selection(in regions: [String?: [MapNode]]) -> String? {
        let main = store.mainGroup?.now.flatMap(store.region(of:))
        return [chosen, main].compactMap { $0 }.first { !nodes(of: $0, in: regions).isEmpty }
    }

    private func nodes(of code: String, in regions: [String?: [MapNode]]) -> [MapNode] {
        (code == Self.unknownRegion ? regions[nil] : regions[code]) ?? []
    }
}

struct MapNode: Identifiable, Hashable {
    let name: String
    let delay: Int?
    var id: String { name }
}

/// The title, the map at the card's full width, and what the colors mean.
private struct MapCard: View {
    let regions: [String?: [MapNode]]
    let selected: String?
    let choose: (String) -> Void

    private var summary: String {
        let places = regions.keys.compactMap { $0 }.count
        let nodes = regions.values.reduce(0) { $0 + $1.count }
        return String(localized: "\(String(places)) 个地区 · \(String(nodes)) 个节点")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("节点分布").font(.headline)
                Text(verbatim: summary).font(.callout).foregroundStyle(.secondary)
            }
            WorldMap(regions: regions, selected: selected, choose: choose)
            legend
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .panel()
    }

    @Environment(\.pageTargetWidth) private var targetWidth

    /// Wrapped at the card's width once the Agent panel has stopped, the same as its width at rest.
    /// Wrapped at its width on the way, it went from one line to two and back, and moved everything
    /// below it. Never wider than the card: mid-motion, the page's edge covers what does not fit.
    @ViewBuilder private var legend: some View {
        let items = FlowLayout(spacing: Spacing.md) { latencyItems; coverageDivider; coverageItems }
        if let targetWidth {
            items
                .frame(width: NodeMapLayout.cardInsideWidth(pageWidth: targetWidth), alignment: .leading)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        } else {
            items
        }
    }

    @ViewBuilder private var latencyItems: some View {
        legend(.success, String(localized: "低于 200 ms"))
        legend(.warning, String(localized: "200 到 500 ms"))
        legend(.failure, String(localized: "更慢或失败"))
        legend(.neutral, String(localized: "未测速"))
    }

    private var coverageDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: Spacing.md)
    }

    @ViewBuilder private var coverageItems: some View {
        coverage(1, String(localized: "1 到 2 个节点"))
        coverage(3, String(localized: "3 到 9 个节点"))
        coverage(10, String(localized: "10 个以上"))
    }

    private func coverage(_ count: Int, _ title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            RoundedRectangle(cornerRadius: Radius.tiny).fill(WorldMap.shade(count)).frame(width: Spacing.md, height: Spacing.sm)
            Text(verbatim: title).lineLimit(1)
        }
    }

    private func legend(_ kind: StatusKind, _ title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(kind.color).frame(width: Spacing.sm, height: Spacing.sm)
            Text(verbatim: title).lineLimit(1)
        }
    }
}

/// Countries from Natural Earth (public domain) in an equirectangular projection, shaded by how
/// many nodes they have, with a dot for each region that has nodes. Regions too small to have a
/// shape at this scale (Singapore, Hong Kong) are the dot alone.
private struct WorldMap: View {
    let regions: [String?: [MapNode]]
    let selected: String?
    let choose: (String) -> Void
    @State private var hoveredDot: String?
    @State private var hoveredCountry: String?
    @Environment(\.pageTargetWidth) private var pageTargetWidth

    /// The map's width once the Agent panel has stopped: the map card's inside.
    private var targetMapWidth: CGFloat? { pageTargetWidth.map(NodeMapLayout.cardInsideWidth(pageWidth:)) }

    /// Latitudes shown: Antarctica and the far north add nothing here.
    static let north = 84.0, south = -58.0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let codes = regions.keys.compactMap { $0 }.sorted()
            let hovered = hoveredDot ?? hoveredCountry
            let positions = dotPositions(codes, in: size)
            ZStack(alignment: .topLeading) {
                MapDrawing(key: "countries", width: size.width, targetWidth: targetMapWidth) { CountriesLayer() }
                MapDrawing(key: "coverage \(counts.sorted { $0.key < $1.key })", width: size.width, targetWidth: targetMapWidth) {
                    CoverageLayer(counts: counts)
                }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { hoveredCountry = country(at: location, in: size) } else { hoveredCountry = nil }
                    }
                    .onTapGesture { location in
                        if let code = country(at: location, in: size) { choose(code) }
                    }
                SelectedOutline(selected: selected)
                ForEach(codes, id: \.self) { code in
                    if let place = NodeLocator.place(code), let nodes = regions[code], let position = positions[code] {
                        dot(place: place, nodes: nodes)
                            .position(position)
                            .zIndex(hovered == code || selected == code ? 1 : 0)
                    }
                }
                if let hovered, let place = NodeLocator.place(hovered), let nodes = regions[hovered], let position = positions[hovered] {
                    tooltip(place: place, nodes: nodes, at: position, in: size)
                        .zIndex(2)
                }
            }
        }
        .aspectRatio(360 / (Self.north - Self.south), contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func dot(place: NodeLocator.Place, nodes: [MapNode]) -> some View {
        let best = nodes.map(\.delay).reduce(nil, NodeMapView.better)
        let isSelected = selected == place.code
        let size: CGFloat = isSelected ? 28 : 22
        return Button { choose(place.code) } label: {
            Text(verbatim: "\(nodes.count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(Spacing.xxs)
                .frame(width: size, height: size)
                .background(Format.delayKind(best).color, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: isSelected ? 2.5 : 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredDot = place.code } else if hoveredDot == place.code { hoveredDot = nil }
        }
        .accessibilityLabel(String(localized: "\(place.name)，\(String(nodes.count)) 个节点，最低延迟 \(Format.delay(best))"))
        .animation(Motion.standard, value: isSelected)
    }

    /// Above the dot, kept inside the map; below it for regions at the map's top edge.
    private func tooltip(place: NodeLocator.Place, nodes: [MapNode], at point: CGPoint, in size: CGSize) -> some View {
        let best = nodes.map(\.delay).reduce(nil, NodeMapView.better)
        let margin: CGFloat = 130, offset: CGFloat = 32
        return Text(String(localized: "\(place.flag) \(place.name)：\(String(nodes.count)) 个节点，最低延迟 \(Format.delay(best))"))
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .position(x: min(max(point.x, margin), max(margin, size.width - margin)),
                      y: point.y > offset + Spacing.sm ? point.y - offset : point.y + offset)
            .allowsHitTesting(false)
    }

    static func project(longitude: Double, latitude: Double, in size: CGSize) -> CGPoint {
        let clamped = min(max(latitude, south), north)
        return CGPoint(x: (longitude + 180) / 360 * size.width, y: (north - clamped) / (north - south) * size.height)
    }

    /// Crowded regions (western Europe, say) moved just far enough apart to read and click; the
    /// shading still shows where they are.
    private func dotPositions(_ codes: [String], in size: CGSize) -> [String: CGPoint] {
        var points: [String: CGPoint] = [:]
        for code in codes {
            if let place = NodeLocator.place(code) { points[code] = Self.project(longitude: place.longitude, latitude: place.latitude, in: size) }
        }
        return MapDots.spread(points, spacing: 26, in: size)
    }

    private var counts: [String: Int] {
        var counts: [String: Int] = [:]
        for (code, nodes) in regions { if let code { counts[code] = nodes.count } }
        return counts
    }

    /// The listed region whose shape holds `location`.
    private func country(at location: CGPoint, in size: CGSize) -> String? {
        let longitude = location.x / size.width * 360 - 180
        let latitude = Self.north - location.y / size.height * (Self.north - Self.south)
        return Self.countries.first { shape in
            guard let code = shape.code, regions[code] != nil else { return false }
            return shape.contains(longitude: longitude, latitude: latitude)
        }?.code
    }

    /// A country with this many nodes: the same three steps as the legend.
    static func shade(_ count: Int) -> Color {
        Color.veerAccent.opacity(count >= 10 ? 0.72 : count >= 3 ? 0.46 : 0.24)
    }

    private static func path(_ shape: MapCountry, in size: CGSize) -> Path {
        var path = Path()
        for ring in shape.rings {
            for (index, point) in ring.enumerated() {
                let p = project(longitude: point[0], latitude: point[1], in: size)
                index == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
        }
        return path
    }

    /// Every country, on its own so that hovering and choosing do not redraw them.
    private struct CountriesLayer: View {
        var body: some View {
            Canvas { context, size in
                for shape in WorldMap.countries {
                    let path = WorldMap.path(shape, in: size)
                    context.fill(path, with: .color(Color.secondary.opacity(0.18)), style: FillStyle(eoFill: true))
                    context.stroke(path, with: .color(Color.surfaceRaised), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// The countries with nodes.
    private struct CoverageLayer: View {
        let counts: [String: Int]

        var body: some View {
            Canvas { context, size in
                for shape in WorldMap.countries {
                    guard let code = shape.code, let count = counts[code] else { continue }
                    let path = WorldMap.path(shape, in: size)
                    context.fill(path, with: .color(WorldMap.shade(count)), style: FillStyle(eoFill: true))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// The chosen country's outline, drawn live at every width so that it stays 1.5 pt: in the
    /// scaled picture it thinned with the map. One country is cheap to draw.
    private struct SelectedOutline: View {
        let selected: String?

        var body: some View {
            Canvas { context, size in
                for shape in WorldMap.countries where shape.code != nil && shape.code == selected {
                    context.stroke(WorldMap.path(shape, in: size), with: .color(Color.veerAccent), lineWidth: 1.5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Loaded once from the app bundle.
    static let countries: [MapCountry] = {
        guard let url = Bundle.main.url(forResource: "countries-110m", withExtension: "json", subdirectory: "Map")
                ?? Bundle.main.url(forResource: "countries-110m", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MapCountry].self, from: data)) ?? []
    }()
}

/// The regions by node count, as cards. Nodes the names say nothing about come last.
private struct RegionGrid: View {
    let regions: [String?: [MapNode]]
    let selected: String?
    let choose: (String) -> Void

    @Environment(\.pageTargetWidth) private var targetWidth

    /// As many as fit the width the page has or is going to, so the cards do not move from three
    /// columns to two and back while the Agent panel moves; then they only stretch.
    private var columns: [GridItem] {
        guard let targetWidth else { return [GridItem(.adaptive(minimum: NodeMapLayout.regionCardWidth), spacing: Spacing.sm)] }
        let count = NodeMapLayout.regionColumns(pageWidth: targetWidth)
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: Spacing.sm), count: count)
    }

    private var sortedCodes: [String] {
        regions.keys.compactMap { $0 }.sorted { (regions[$0]?.count ?? 0, $1) > (regions[$1]?.count ?? 0, $0) }
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.sm) {
            ForEach(sortedCodes, id: \.self) { code in
                if let place = NodeLocator.place(code), let nodes = regions[code] {
                    card(code: code, title: "\(place.flag) \(place.name)", nodes: nodes)
                }
            }
            if let unknown = regions[nil], !unknown.isEmpty {
                card(code: NodeMapView.unknownRegion, title: String(localized: "未识别"), nodes: unknown)
            }
        }
    }

    private func card(code: String, title: String, nodes: [MapNode]) -> some View {
        let best = nodes.map(\.delay).reduce(nil, NodeMapView.better)
        let isSelected = selected == code
        return Button { choose(code) } label: {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Spacing.xs)
                Text(verbatim: "\(nodes.count)").foregroundStyle(.secondary).monospacedDigit()
                Text(Format.delay(best)).font(.caption.monospacedDigit()).foregroundStyle(Format.delayKind(best).color)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(isSelected ? Color.veerAccent.opacity(0.14) : Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(isSelected ? Color.veerAccent : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The chosen region's nodes as cards; choosing one uses it in the main group when it can.
private struct RegionNodes: View {
    @Environment(ProxyStore.self) private var store
    let code: String
    let nodes: [MapNode]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                if let place = NodeLocator.place(code) {
                    Text(verbatim: "\(place.flag) \(place.name)").font(.headline)
                } else {
                    Text("未识别").font(.headline)
                }
                Text("\(String(nodes.count)) 个节点").font(.callout).foregroundStyle(.secondary)
            }
            if code == NodeMapView.unknownRegion {
                Text("在代理页的节点上右键，可以手动标记地区。").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.sm)], spacing: Spacing.sm) {
                ForEach(nodes) { card($0) }
            }
        }
        .panel()
    }

    private func card(_ node: MapNode) -> some View {
        let main = store.mainGroup
        let usable = main.map { $0.isSelectable && $0.members.contains { $0.name == node.name } } ?? false
        let inUse = main?.now == node.name
        return Button { if let main, usable { store.select(node.name, in: main.name) } } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: inUse ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(inUse ? Color.veerAccent : Color.secondary)
                    .opacity(usable ? 1 : 0)
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if store.regionIsFromIP(node.name) {
                    Text(verbatim: "IP").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.xs).background(Color.subtleFill, in: Capsule())
                        .help(String(localized: "按服务器 IP 推断的地区；中转节点的入口和出口可能不在同一个地方，可以右键手动标记。"))
                }
                Spacer(minLength: Spacing.xs)
                Text(Format.delay(node.delay)).font(.caption.monospacedDigit()).foregroundStyle(Format.delayKind(node.delay).color)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(inUse ? Color.veerAccent.opacity(0.14) : Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .help(usable ? String(localized: "在“\(main?.name ?? "")”中使用这个节点") : node.name)
    }
}

/// A map layer drawn once into a picture and shown scaled. Its outlines are a few thousand points,
/// which drawing again at every width cost the Agent panel's motion every other frame; a picture
/// only scales. It is drawn at the map's width once the panel stops, so at rest its lines are
/// exact, and again when what it shows or the appearance changes. With Increase Contrast on, the
/// layer itself: a picture cannot be given that setting.
private struct MapDrawing<Layer: View>: View {
    let key: String
    /// The map's width now, and once the Agent panel has stopped (nil outside the main window).
    let width: CGFloat
    let targetWidth: CGFloat?
    @ViewBuilder var layer: () -> Layer
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @State private var drawn: Image?

    private var pictureWidth: CGFloat { NodeMapLayout.pictureWidth(mapWidth: width, targetMapWidth: targetWidth) }
    private var size: CGSize { CGSize(width: pictureWidth, height: pictureWidth * (WorldMap.north - WorldMap.south) / 360) }

    private var currentKey: String { "\(key) \(colorScheme) \(contrast) \(displayScale) \(pictureWidth)" }

    var body: some View {
        Group {
            // The last picture, scaled, until the new one is drawn: the layer itself in between
            // would cost the frame the picture saves.
            if contrast == .standard, let drawn {
                drawn.resizable().interpolation(.high)
            } else {
                // Until the first picture is ready, the layer itself.
                layer()
            }
        }
        .accessibilityHidden(true)
        .task(id: currentKey) { if contrast == .standard { draw() } }
    }

    private func draw() {
        let renderer = ImageRenderer(content: layer()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = displayScale
        if let image = renderer.cgImage { drawn = Image(decorative: image, scale: displayScale) }
    }
}

/// The node map's width rules, chosen from the width the page has or is going to.
nonisolated enum NodeMapLayout {
    static let regionCardWidth: CGFloat = 220

    /// Region cards at least 220 wide, 8 apart, inside the page's 24 pt margins.
    static func regionColumns(pageWidth: CGFloat) -> Int {
        max(1, Int((pageWidth - 2 * Spacing.xl + Spacing.sm) / (regionCardWidth + Spacing.sm)))
    }

    /// The map card's inside, where the map and its legend are, on a page this wide: less the
    /// page's 24 pt margins and the card's 16 pt padding on each side.
    static func cardInsideWidth(pageWidth: CGFloat) -> CGFloat {
        max(0, pageWidth - 2 * Spacing.xl - 2 * Spacing.lg)
    }

    /// The map's width once the Agent panel has stopped, so it is drawn once as the motion starts
    /// and never at the widths on the way; its own width outside the main window.
    static func pictureWidth(mapWidth: CGFloat, targetMapWidth: CGFloat?) -> CGFloat {
        max(1, (targetMapWidth ?? mapWidth).rounded(.up))
    }
}
