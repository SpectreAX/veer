import SwiftUI
import VeerCore
import VeerProxy

/// Nodes on a world map, the chosen region's nodes right below it, and every region below those.
/// The map's greens say how many nodes each region has; choosing a region, on the map or below it,
/// brings the map in on it and shows its nodes and delays. Choosing a node uses it in the main group
/// when that group has it.
struct NodeMapView: View {
    @Environment(ProxyStore.self) private var store
    /// The toolbar's search: nodes whose name or region contains it.
    var query = ""
    /// Empties the search; offered when it matches nothing.
    var clearSearch: (() -> Void)?
    /// A region code or `unknownRegion`; until the user chooses, the region of the node in use.
    @State private var chosen: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let unknownRegion = "unknown"

    /// Every real node in the running config with its best known delay, by region code; nodes
    /// whose region is unknown are under nil.
    static func regions(in store: ProxyStore, matching query: String) -> [String?: [MapNode]] {
        var best: [String: Int?] = [:], states: [String: NodeDelay] = [:]
        for group in store.groups {
            // Subscriptions list their traffic and expiry as fake nodes; they exit nowhere.
            for member in group.members where !member.isGroup && !Self.builtins.contains(member.name) && !NodeCleanup.isInfoNode(member.name) {
                let latest = store.delays[member.name]
                let known = best[member.name] ?? nil
                best[member.name] = Self.better(known, latest?.legacyDelay ?? member.delay)
                // The same node in every group has one state: Veer tests nodes, not group members.
                states[member.name] = latest ?? member.state
            }
        }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let nodes = best.map { MapNode(name: $0.key, delay: $0.value, state: states[$0.key] ?? NodeDelay(history: $0.value)) }
        let all = Dictionary(grouping: nodes.sorted { $0.name < $1.name }) {
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
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let regions = Self.regions(in: store, matching: text)
        let current = store.mainGroup?.now.flatMap(store.region(of:))
        let selected = Self.selection(chosen: chosen, current: current, in: regions, filtering: !text.isEmpty)
        // The same scroll view whatever the search finds: taking it away for an empty state would
        // take the keyboard focus out of the search field, in the middle of typing.
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // A search that finds nothing says so in the map's place: an empty map, its
                    // zero counts and legend only pushed the answer, and the way back, out of sight.
                    if Self.searchFoundNothing(regions, query: text) {
                        StateView(symbol: "magnifyingglass", title: String(localized: "没有匹配“\(text)”的节点或地区"),
                                  actionTitle: clearSearch == nil ? nil : String(localized: "清除搜索"), action: clearSearch)
                            .frame(minHeight: 320)
                    } else {
                        // The map zooms only on an explicit choice, including when search shows one region.
                        MapCard(regions: regions, selected: selected, focus: chosen == selected ? chosen : nil) { chosen = $0 }
                    }
                    if regions.isEmpty {
                        if text.isEmpty { Text(String(localized: "没有可显示在地图上的节点。")).font(.callout) }
                    } else {
                        // The scroll target exists even before a region has been selected.
                        VStack(alignment: .leading) {
                            if let selected {
                                RegionNodes(code: selected, nodes: Self.nodes(of: selected, in: regions))
                            } else {
                                Text("选择一个地区查看节点").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .id("SelectedRegionNodes")
                        RegionGrid(regions: regions, selected: selected) {
                            chosen = $0
                            withAnimation(reduceMotion ? nil : Motion.panel) {
                                reader.scrollTo("SelectedRegionNodes", anchor: .top)
                            }
                        }
                    }
                }
                .padding(Spacing.xl)
            }
        }
    }

    /// A region as VoiceOver reads it, on the map and on its card: its name, its node count and its best
    /// delay. No flag: VoiceOver reads a flag as the country's name a second time.
    static func regionSummary(_ code: String, nodes: [MapNode]) -> String {
        // A word where the page shows a dash, which VoiceOver reads as nothing or as "dash".
        let best = MapNode.bestDelay(in: nodes).map { Format.delay($0) } ?? String(localized: "未测速")
        let name = NodeLocator.place(code)?.name ?? String(localized: "未识别")
        return String(localized: "\(name)，\(String(nodes.count)) 个节点，最低延迟 \(best)")
    }

    /// A search is in and no node's name or region contains it.
    static func searchFoundNothing(_ regions: [String?: [MapNode]], query: String) -> Bool {
        regions.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the user chose, else the region of the node in use, if it is still listed.
    static func selection(chosen: String?, current: String?, in regions: [String?: [MapNode]], filtering: Bool) -> String? {
        let available = [chosen, current].compactMap { $0 }.first { !nodes(of: $0, in: regions).isEmpty }
        guard available == nil, filtering, regions.count == 1, let only = regions.keys.first else { return available }
        return only ?? unknownRegion
    }

    private static func nodes(of code: String, in regions: [String?: [MapNode]]) -> [MapNode] {
        (code == Self.unknownRegion ? regions[nil] : regions[code]) ?? []
    }
}

struct MapNode: Identifiable, Hashable {
    let name: String
    let delay: Int?
    var state: NodeDelay = .untested
    var id: String { name }

    static func bestDelay(in nodes: [Self]) -> Int? {
        nodes.compactMap(\.delay).filter { $0 > 0 }.min()
    }
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
                Text(verbatim: summary).font(.callout)
            }
            WorldMap(regions: regions, selected: selected, focus: focus, choose: choose)
            legend.font(.caption)
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
        .accessibilityValue(selectionDescription ?? String(localized: "没有选中地区；地区在下面的列表里"))
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

    /// A short label on the map. The region's details sit in the card directly below.
    private var callout: MapSurface.Callout? {
        guard let selected, let place = NodeLocator.place(selected) else { return nil }
        return MapSurface.Callout(text: "\(place.flag) \(place.name)", anchor: Self.anchor(of: selected))
    }

    private var selectionDescription: String? {
        guard let selected, let nodes = regions[selected == NodeMapView.unknownRegion ? nil : selected] else { return nil }
        return NodeMapView.regionSummary(selected, nodes: nodes)
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
                // While zoomed in, Show Whole Map sits in the top trailing corner; the label keeps clear of it.
                label(callout.text, at: viewport.point(anchor, in: size),
                      avoiding: viewport.scale > 1 ? MapCalloutLayout.buttonArea(in: size) : nil)
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
    private func label(_ text: String, at point: CGPoint, avoiding: CGRect?) -> some View {
        MapCalloutLayout(point: point, avoiding: avoiding) {
            Text(verbatim: text)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Places the map's region label by its rendered size, so a short label can sit next to a region at
/// the map's edge instead of being kept as far in as the widest label would need.
struct MapCalloutLayout: Layout {
    let point: CGPoint
    /// A part of the map the label must not cover: the Show Whole Map button, while it is shown.
    var avoiding: CGRect?
    /// From the region's point to the label's center, above it or below it.
    static let offset: CGFloat = 32
    static let inset = Spacing.xs
    static let maxWidth: CGFloat = 300

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let width = max(0, min(Self.maxWidth, bounds.width - 2 * Self.inset))
        let size = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let center = Self.center(for: point, label: size, in: bounds.size, avoiding: avoiding)
        label.place(at: CGPoint(x: bounds.minX + center.x, y: bounds.minY + center.y), anchor: .center,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
    }

    /// The label's center: over the point where its width allows, held inside the map by its own
    /// half width; above the point unless that would leave the top.
    static func center(for point: CGPoint, label: CGSize, in map: CGSize, avoiding: CGRect? = nil) -> CGPoint {
        let margin = label.width / 2 + inset
        let x = 2 * margin > map.width ? map.width / 2 : min(max(point.x, margin), map.width - margin)
        var y = point.y > offset + Spacing.lg ? point.y - offset : point.y + offset
        // Inside the map top to bottom too, when it is tall enough: in the narrow map the label below a
        // region near the bottom edge was cut off.
        let half = label.height / 2 + inset
        if map.height >= 2 * half { y = min(max(y, half), map.height - half) }
        let placed = CGPoint(x: x, y: y)
        guard let avoiding, frame(placed, label).intersects(avoiding) else { return placed }
        // The other side of the region, if that stays inside the map and clear of the area.
        let other = CGPoint(x: x, y: y < point.y ? point.y + offset : point.y - offset)
        let otherFrame = frame(other, label)
        if otherFrame.minY >= 0, otherFrame.maxY <= map.height, !otherFrame.intersects(avoiding) { return other }
        // A region in the area's band: just below the area, still over the region, not over a neighbor.
        let below = CGPoint(x: x, y: avoiding.maxY + inset + label.height / 2)
        if point.y < avoiding.maxY, frame(below, label).maxY <= map.height { return below }
        // Else beside the area, toward the map's leading side, when the map is wide enough for that.
        let beside = avoiding.minX - inset - label.width / 2
        return beside - label.width / 2 >= inset ? CGPoint(x: beside, y: y) : placed
    }

    /// Where Show Whole Map sits: the map's top trailing corner, a small button, its padding and a gap.
    static func buttonArea(in map: CGSize) -> CGRect {
        CGRect(x: map.width - 40, y: 0, width: 40, height: 32)
    }

    private static func frame(_ center: CGPoint, _ label: CGSize) -> CGRect {
        CGRect(x: center.x - label.width / 2, y: center.y - label.height / 2, width: label.width, height: label.height)
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
        let best = MapNode.bestDelay(in: nodes)
        let isSelected = selected == code
        return Button { choose(code) } label: {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Spacing.xs)
                Text(verbatim: "\(nodes.count)").monospacedDigit()
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
        // Read as one name rather than its parts ("Japan, 2, 92 ms" left the 2 and the delay unexplained).
        .accessibilityLabel(NodeMapView.regionSummary(code, nodes: nodes))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The chosen region's nodes as cards; choosing one uses it in the main group when it can.
private struct RegionNodes: View {
    @Environment(ProxyStore.self) private var store
    let code: String
    let nodes: [MapNode]

    /// The scope its test runs under, so it neither waits for nor stops another group's.
    private var scope: LatencyScope { .region(code) }
    private var place: NodeLocator.Place? { NodeLocator.place(code) }
    private var name: String { place?.name ?? String(localized: "未识别") }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BlendedHeader(spacing: Spacing.sm, rowSpacing: Spacing.xs) {
                Text(verbatim: place.map { "\($0.flag) \($0.name)" } ?? name).font(.headline).lineLimit(1)
                Text("\(String(nodes.count)) 个节点").font(.callout).lineLimit(1)
                let best = MapNode.bestDelay(in: nodes)
                Text(String(localized: "最低延迟 \(Format.delay(best))")).font(.callout).lineLimit(1)
                // Spinner and button share one place, so the header does not move.
                ZStack(alignment: .trailing) {
                    Button("测速") { store.testNodes(nodes.map(\.name), scope: scope) }
                        .secondaryAction()
                        .fixedSize()
                        .opacity(testing ? 0 : 1)
                        .disabled(!store.canStartLatencyTest(scope))
                        .accessibilityLabel(String(localized: "为“\(name)”测速"))
                        .accessibilityHidden(testing)
                        .help(String(localized: "只测试这个地区的 \(String(nodes.count)) 个节点，不改变任何策略组的选择"))
                    if testing { ProgressView().controlSize(.small).accessibilityLabel(String(localized: "正在测速")) }
                }
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

    private var testing: Bool { store.testingScopes.contains(scope) }

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
                let color = node.state == .testing || node.state == .coreNotReady ? Color.primary : Format.delayKind(node.state).color
                Text(Format.delay(node.state)).font(.caption.monospacedDigit()).foregroundStyle(color)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(inUse ? Color.veerAccent.opacity(0.14) : Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityAddTraits(inUse ? .isSelected : [])
        .help(usable ? String(localized: "在“\(main?.name ?? "")”中使用这个节点") : node.name)
        .contextMenu { Menu("标记地区") { RegionMarkItems(node: node.name) } }
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
