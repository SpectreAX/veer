import SwiftUI
import VeerCore
import VeerProxy

/// Nodes on a world map, with the regions below it and the chosen region's nodes below those.
/// The map's greens say how many nodes each region has; choosing a region, on the map or below it,
/// brings the map in on it and shows its nodes and delays. Choosing a node uses it in the main group
/// when that group has it.
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
                // Brought in on a region only once the person has chosen one: the region of the node in
                // use is marked, with the whole map in view.
                MapCard(regions: regions, selected: selected, focus: chosen == selected ? chosen : nil) { chosen = $0 }
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
    /// The region the map is brought in on.
    let focus: String?
    /// A region, or nil to go back to the whole map.
    let choose: (String?) -> Void

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
            WorldMap(regions: regions, selected: selected, focus: focus, choose: choose)
            legend
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .panel()
    }

    /// The map's steps of green, and nothing else: delays are in the chosen region and its nodes.
    /// Wrapped at the card's own width at every frame.
    private var legend: some View {
        FlowLayout(spacing: Spacing.md) {
            step(0, String(localized: "没有节点"))
            step(1, String(localized: "1 到 2 个节点"))
            step(3, String(localized: "3 到 9 个节点"))
            step(10, String(localized: "10 到 19 个"))
            step(20, String(localized: "20 个以上"))
        }
    }

    private func step(_ count: Int, _ title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            RoundedRectangle(cornerRadius: Radius.tiny).fill(WorldMap.fill(count)).frame(width: Spacing.md, height: Spacing.sm)
            Text(verbatim: title).lineLimit(1)
        }
    }
}

/// Countries from Natural Earth (public domain) in an equirectangular projection, each filled by
/// how many nodes it has: a choropleth, with no badge on any region. Regions too small to have a
/// shape at this scale (Singapore, Hong Kong) are a small mark of the same green. Choosing a region
/// brings the map in on it and names it with its nodes and best delay; the map can also be pinched
/// and dragged, and put back.
private struct WorldMap: View {
    let regions: [String?: [MapNode]]
    let selected: String?
    let focus: String?
    let choose: (String?) -> Void
    @State private var viewport = MapViewport.world
    /// Where a drag or pinch started.
    @State private var gestureStart: MapViewport?
    @State private var hovered: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A mark this far from the pointer takes the click, so a region with no shape can be chosen.
    private static let markReach: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            MapSurface(viewport: viewport, counts: counts, selected: selected, hovered: hovered, callout: callout)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let location) = phase { hovered = region(at: location, in: size) } else { hovered = nil }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    // A region is chosen; anywhere else puts the whole map back.
                    choose(region(at: tap.location, in: size))
                })
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        guard viewport.scale > 1 else { return }
                        let start = gestureStart ?? viewport
                        gestureStart = start
                        viewport = start.panned(by: drag.translation, in: size)
                    }
                    .onEnded { _ in gestureStart = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { pinch in
                        let start = gestureStart ?? viewport
                        gestureStart = start
                        viewport = MapViewport(scale: start.scale * pinch.magnification, center: start.center)
                    }
                    .onEnded { _ in gestureStart = nil })
                .overlay(alignment: .topTrailing) {
                    if viewport != .world {
                        Button { choose(nil); show(.world) } label: { Label(String(localized: "显示整张地图"), systemImage: "arrow.up.left.and.arrow.down.right") }
                            .labelStyle(.iconOnly)
                            .secondaryAction()
                            .controlSize(.small)
                            .help("显示整张地图")
                            .padding(Spacing.xs)
                    }
                }
        }
        .aspectRatio(MapProjection.aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "节点分布地图"))
        .accessibilityValue(callout?.text ?? String(localized: "没有选中地区；地区在下面的列表里"))
        // In on the region chosen, or back out.
        .onChange(of: focus, initial: true) { _, focus in show(focus.flatMap(Self.viewport(for:)) ?? .world) }
    }

    private func show(_ target: MapViewport) {
        withAnimation(reduceMotion ? nil : Motion.panel) { viewport = target }
    }

    private var counts: [String: Int] {
        var counts: [String: Int] = [:]
        for (code, nodes) in regions { if let code { counts[code] = nodes.count } }
        return counts
    }

    /// The chosen region's name, nodes and best delay, and where it is on the map.
    private var callout: MapSurface.Callout? {
        guard let selected, let place = NodeLocator.place(selected), let nodes = regions[selected] else { return nil }
        let best = nodes.map(\.delay).reduce(nil, NodeMapView.better)
        return MapSurface.Callout(text: String(localized: "\(place.flag) \(place.name)：\(String(nodes.count)) 个节点，最低延迟 \(Format.delay(best))"),
                                  anchor: Self.anchor(of: selected))
    }

    /// The listed region at a point of the view: a small region's mark when the point is near one,
    /// else the country whose shape holds it.
    private func region(at location: CGPoint, in size: CGSize) -> String? {
        let marks = counts.keys.filter(Self.isMarked).compactMap { code in Self.anchor(of: code).map { (code, viewport.point($0, in: size)) } }
        if let near = marks.min(by: { hypot($0.1.x - location.x, $0.1.y - location.y) < hypot($1.1.x - location.x, $1.1.y - location.y) }),
           hypot(near.1.x - location.x, near.1.y - location.y) <= Self.markReach {
            return near.0
        }
        let coordinate = MapProjection.coordinate(viewport.unit(location, in: size))
        return Self.shapes.first { shape in
            guard let code = shape.code, counts[code] != nil else { return false }
            return shape.country.contains(longitude: coordinate.longitude, latitude: coordinate.latitude)
        }?.code
    }

    // MARK: Geometry, made once

    struct Shape {
        let code: String?
        let country: MapCountry
        /// The outline in the map's unit square.
        let path: Path
        let bounds: CGRect
    }

    /// Every country with its outline already projected: parsed and projected once, whatever the
    /// nodes, the delays or the view do afterward.
    static let shapes: [Shape] = {
        guard let url = Bundle.main.url(forResource: "countries-110m", withExtension: "json", subdirectory: "Map")
                ?? Bundle.main.url(forResource: "countries-110m", withExtension: "json"),
              let data = try? Data(contentsOf: url), let countries = try? JSONDecoder().decode([MapCountry].self, from: data) else { return [] }
        return countries.map { country in
            var path = Path()
            for ring in country.rings {
                for (index, point) in ring.enumerated() where point.count >= 2 {
                    let unit = MapProjection.unit(longitude: point[0], latitude: point[1])
                    if index == 0 { path.move(to: unit) } else { path.addLine(to: unit) }
                }
                path.closeSubpath()
            }
            return Shape(code: country.code, country: country, path: path, bounds: country.unitBounds)
        }
    }()

    private static let boundsByCode: [String: CGRect] = {
        var bounds: [String: CGRect] = [:]
        for shape in shapes { if let code = shape.code { bounds[code] = shape.bounds } }
        return bounds
    }()

    /// A region with no shape on this map, or one too small to see or click at its size.
    static func isMarked(_ code: String) -> Bool {
        guard let bounds = boundsByCode[code] else { return true }
        return bounds.width * bounds.height < 0.00004
    }

    /// Where a region is: where its nodes usually are, else the middle of its shape.
    static func anchor(of code: String) -> CGPoint? {
        if let place = NodeLocator.place(code) { return MapProjection.unit(longitude: place.longitude, latitude: place.latitude) }
        return boundsByCode[code].map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The view that shows a region with the land around it.
    static func viewport(for code: String) -> MapViewport? {
        if let bounds = boundsByCode[code], !isMarked(code) { return .showing(bounds) }
        return anchor(of: code).map { MapViewport(scale: 5, center: $0) }
    }

    /// A region with this many nodes: the steps of the legend. None is a neutral gray.
    static func fill(_ count: Int) -> Color {
        switch MapTier.tier(count) {
        case 0: Color.secondary.opacity(0.18)
        case 1: Color.veerAccent.opacity(0.26)
        case 2: Color.veerAccent.opacity(0.48)
        case 3: Color.veerAccent.opacity(0.70)
        default: Color.veerAccent.opacity(0.92)
        }
    }
}

/// The map as drawn for one view of it. The view is the one thing animated, so going in on a region
/// redraws the outlines, already projected, under a new transform at every frame, and the chosen
/// region's name moves with them.
private struct MapSurface: View, Animatable {
    var viewport: MapViewport
    let counts: [String: Int]
    let selected: String?
    let hovered: String?
    let callout: Callout?

    struct Callout: Equatable {
        let text: String
        /// Where the region is, in the map's unit square.
        let anchor: CGPoint?
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(viewport.scale, AnimatablePair(viewport.center.x, viewport.center.y)) }
        set { viewport = MapViewport(scale: newValue.first, center: CGPoint(x: newValue.second.first, y: newValue.second.second)) }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, size in draw(&context, size: size) }
                .accessibilityHidden(true)
            if let callout, let anchor = callout.anchor {
                label(callout.text, at: viewport.point(anchor, in: size), in: size)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let transform = viewport.transform(in: size)
        var chosen: Path?, pointed: Path?
        for shape in WorldMap.shapes {
            let path = shape.path.applying(transform)
            context.fill(path, with: .color(WorldMap.fill(shape.code.flatMap { counts[$0] } ?? 0)), style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(Color.surfaceRaised), lineWidth: 0.5)
            if let code = shape.code, counts[code] != nil {
                if code == selected { chosen = path } else if code == hovered { pointed = path }
            }
        }
        // Regions with no shape to fill: a mark of the same green.
        for code in counts.keys.sorted() where WorldMap.isMarked(code) {
            guard let anchor = WorldMap.anchor(of: code) else { continue }
            let center = viewport.point(anchor, in: size), radius: CGFloat = code == selected ? 6 : 4.5
            let mark = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(mark, with: .color(Color.surfaceRaised))
            context.fill(mark, with: .color(WorldMap.fill(counts[code] ?? 0)))
            context.stroke(mark, with: .color(code == selected ? Color.veerAccent : Color.primary.opacity(code == hovered ? 0.6 : 0.3)),
                           lineWidth: code == selected ? 2 : 1)
        }
        if let pointed { context.stroke(pointed, with: .color(Color.primary.opacity(0.45)), lineWidth: 1) }
        if let chosen { context.stroke(chosen, with: .color(Color.veerAccent), lineWidth: 2) }
    }

    /// Above the region, kept inside the map; below it for regions at the map's top edge.
    private func label(_ text: String, at point: CGPoint, in size: CGSize) -> some View {
        let margin: CGFloat = 130, offset: CGFloat = 26
        return Text(verbatim: text)
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .position(x: min(max(point.x, margin), max(margin, size.width - margin)),
                      y: point.y > offset + Spacing.lg ? point.y - offset : point.y + offset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The regions by node count, as cards. Nodes the names say nothing about come last.
private struct RegionGrid: View {
    let regions: [String?: [MapNode]]
    let selected: String?
    let choose: (String) -> Void

    private var sortedCodes: [String] {
        regions.keys.compactMap { $0 }.sorted { (regions[$0]?.count ?? 0, $1) > (regions[$1]?.count ?? 0, $0) }
    }

    var body: some View {
        BlendedGrid(minimum: NodeMapLayout.regionCardWidth, spacing: Spacing.sm, rowSpacing: Spacing.sm) {
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
            BlendedGrid(minimum: 240, spacing: Spacing.sm, rowSpacing: Spacing.sm) {
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

/// The node map's width rules, chosen from the width the page has or is going to.
nonisolated enum NodeMapLayout {
    static let regionCardWidth: CGFloat = 220

    /// The map card's inside, where the map and its legend are, on a page this wide: less the
    /// page's 24 pt margins and the card's 16 pt padding on each side.
    static func cardInsideWidth(pageWidth: CGFloat) -> CGFloat {
        max(0, pageWidth - 2 * Spacing.xl - 2 * Spacing.lg)
    }
}
