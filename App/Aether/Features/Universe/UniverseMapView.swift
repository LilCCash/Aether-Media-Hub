import SwiftUI
import UIKit
import AetherCore

/// The universe as a map of its stories: every line is a storyline (Iron Man, the Skywalker saga, Bond's Connery years…), the titles
/// sit on it from left to right in the chosen order, a solid line joins the next title of the same story and a dashed arrow shows
/// where stories meet. It is explored like a map (pinch, drag with inertia, double tap): lines, posters and names are drawn once on
/// one surface that moves and zooms as a whole, so the lines never shift against the titles.
struct UniverseMapView: View {
    let universe: UniverseDefinition
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.imageLoader) private var loader
    @State private var order: UniverseOrder = .release
    @State private var opened: MetaRoute?
    @State private var command = StoryMapCommand(id: 0, kind: .start)

    private var custom: [String]? { return settings.value.content.universes.customOrders[universe.id] }
    private var watched: Set<String> { return Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys) }
    private var orders: [UniverseOrder] { return universe.chronological == nil ? [.release] : [.release, .chronological] }

    var body: some View {
        let map = UniverseStoryMap.build(universe, order: order, custom: custom)
        let seen = watched
        return NavigationStack {
            ZStack {
                Color(red: 0.035, green: 0.04, blue: 0.07).ignoresSafeArea()
                StoryMapSurface(map: map, seen: seen, showsYears: order == .release, command: command, settings: settings, loader: loader) { entry in
                    opened = MetaRoute(type: entry.type, id: entry.id,
                                       preview: MetaItem(id: entry.id, type: entry.type, name: entry.name, poster: UniverseArt.poster(entry.id)))
                }
                .id(order)
                .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 0) {
                    if orders.count > 1 {
                        Picker("Ordine", selection: $order) { ForEach(orders, id: \.self) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, Theme.pageMargin)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                    }
                    Spacer()
                    footer(map, seen: seen)
                }
            }
            .navigationTitle(universe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() }.fontWeight(.semibold) } }
            .navigationDestination(item: $opened) { DetailView(route: $0) }
        }
        .preferredColorScheme(.dark)
    }

    private func footer(_ map: UniverseStoryMap, seen: Set<String>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(map.nodes.filter { seen.contains($0.id) }.count) di \(map.nodes.count) visti · \(map.lanes.count) storie")
                    .font(.footnote.weight(.semibold))
                HStack(spacing: 10) {
                    legend(dashed: false, text: "stessa storia")
                    legend(dashed: true, text: "storie che si incontrano")
                }
                if order == .chronological, let note = universe.chronologicalNote {
                    Text(note).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            mapButton("minus.magnifyingglass", label: "Allontana") { send(.zoomOut) }
            mapButton("plus.magnifyingglass", label: "Avvicina") { send(.zoomIn) }
            mapButton("arrow.up.left.and.arrow.down.right", label: "Tutto l'universo") { send(.overview) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func send(_ kind: StoryMapCommand.Kind) {
        command = StoryMapCommand(id: command.id + 1, kind: kind)
    }

    private func legend(dashed: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 18, y: 4))
            }
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
            .frame(width: 18, height: 8)
            Text(text).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A request from the buttons under the map.
struct StoryMapCommand: Equatable {
    enum Kind { case start, zoomIn, zoomOut, overview }
    var id: Int
    var kind: Kind
}

/// Where everything is on the map, at zoom 1.
struct StoryMapGeometry {
    static let slotWidth: CGFloat = 128
    static let laneHeight: CGFloat = 200
    static let leftPad: CGFloat = 40
    static let topPad: CGFloat = 64
    static let nodeSize = CGSize(width: 110, height: 176)

    static func size(_ map: UniverseStoryMap) -> CGSize {
        return CGSize(width: leftPad * 2 + CGFloat(max(1, map.slotCount)) * slotWidth,
                      height: topPad + CGFloat(max(1, map.lanes.count)) * laneHeight + 120)
    }

    static func center(slot: Int, lane: Int) -> CGPoint {
        return CGPoint(x: leftPad + (CGFloat(slot) + 0.5) * slotWidth, y: topPad + (CGFloat(lane) + 0.5) * laneHeight)
    }

    static func center(_ node: UniverseStoryMap.Node) -> CGPoint { return center(slot: node.slot, lane: node.lane) }

    /// Where the lines meet a poster: its left and right sides, at the height of the poster's middle.
    static var posterMiddle: CGFloat { return -nodeSize.height / 2 + 63 }

    static let palette: [UIColor] = [
        UIColor(red: 0.95, green: 0.27, blue: 0.27, alpha: 1), UIColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 1),
        UIColor(red: 0.25, green: 0.56, blue: 0.98, alpha: 1), UIColor(red: 0.62, green: 0.40, blue: 0.98, alpha: 1),
        UIColor(red: 0.20, green: 0.80, blue: 0.55, alpha: 1), UIColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 1),
        UIColor(red: 0.95, green: 0.38, blue: 0.70, alpha: 1), UIColor(red: 0.30, green: 0.82, blue: 0.90, alpha: 1),
        UIColor(red: 0.70, green: 0.85, blue: 0.30, alpha: 1), UIColor(red: 0.85, green: 0.55, blue: 0.40, alpha: 1),
        UIColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1), UIColor(red: 0.90, green: 0.45, blue: 0.95, alpha: 1),
    ]

    static func color(_ lane: Int) -> UIColor { return palette[lane % palette.count] }
}

/// The scrolling, zooming surface (UIKit's scroll view: native pinch, inertia and bounce).
struct StoryMapSurface: UIViewRepresentable {
    let map: UniverseStoryMap
    let seen: Set<String>
    let showsYears: Bool
    let command: StoryMapCommand
    let settings: SettingsStore
    let loader: ImageLoader?
    let open: (UniverseEntry) -> Void

    func makeUIView(context: Context) -> StoryMapScrollView {
        let view = StoryMapScrollView()
        view.build(map: map, content: content(), size: StoryMapGeometry.size(map))
        view.open = open
        view.handledCommand = command.id
        return view
    }

    func updateUIView(_ view: StoryMapScrollView, context: Context) {
        view.updateContent(content())
        view.open = open
        if command.id != view.handledCommand {
            view.handledCommand = command.id
            view.apply(command.kind)
        }
    }

    private func content() -> AnyView {
        return AnyView(StoryMapContent(map: map, seen: seen, showsYears: showsYears, open: open)
            .environmentObject(settings)
            .environment(\.imageLoader, loader))
    }
}

final class StoryMapScrollView: UIScrollView, UIScrollViewDelegate {
    private let canvas = UIView()
    private var host: UIHostingController<AnyView>?
    private var lineLayers: [CAShapeLayer] = []
    private var contentSizeAtOne: CGSize = .zero
    private var placed = false
    private var nodes: [UniverseStoryMap.Node] = []
    var handledCommand = 0
    var open: ((UniverseEntry) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .normal
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        // A title opens with a tap read here, not by the posters' own buttons: SwiftUI's touch handling inside the map sometimes
        // kept the first finger of a pinch for itself, and the scroll view saw no pinch or drag at all.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func build(map: UniverseStoryMap, content: AnyView, size: CGSize) {
        contentSizeAtOne = size
        nodes = map.nodes
        canvas.frame = CGRect(origin: .zero, size: size)
        addSubview(canvas)
        drawLines(map)
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.frame = canvas.bounds
        host.safeAreaRegions = []
        host.view.isUserInteractionEnabled = false
        canvas.addSubview(host.view)
        self.host = host
        contentSize = size
    }

    func updateContent(_ content: AnyView) {
        host?.rootView = content
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !placed, bounds.width > 0, bounds.height > 0 else { return }
        placed = true
        minimumZoomScale = fitScale * 0.9
        maximumZoomScale = 1.4
        apply(.start)
    }

    private var fitScale: CGFloat {
        guard contentSizeAtOne.width > 0, contentSizeAtOne.height > 0 else { return 0.1 }
        return max(0.02, min(0.6, min(bounds.width / contentSizeAtOne.width, bounds.height / contentSizeAtOne.height)))
    }

    func apply(_ kind: StoryMapCommand.Kind) {
        switch kind {
        case .start:
            // Up to four storylines on screen, from the first title.
            let lanes = min(4, max(1, (contentSizeAtOne.height - StoryMapGeometry.topPad - 120) / StoryMapGeometry.laneHeight))
            let scale = min(1.0, max(minimumZoomScale, bounds.height / (StoryMapGeometry.topPad + lanes * StoryMapGeometry.laneHeight + 140)))
            setZoomScale(scale, animated: false)
            setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false)
        case .zoomIn:
            zoom(by: 1.6, at: CGPoint(x: bounds.midX, y: bounds.midY))
        case .zoomOut:
            zoom(by: 0.6, at: CGPoint(x: bounds.midX, y: bounds.midY))
        case .overview:
            if zoomScale > fitScale * 1.2 {
                setZoomScale(fitScale, animated: true)
            } else {
                apply(.start)
            }
        }
    }

    private func zoom(by factor: CGFloat, at point: CGPoint) {
        let target = min(maximumZoomScale, max(minimumZoomScale, zoomScale * factor))
        let inCanvas = canvas.convert(point, from: self)
        let width = bounds.width / target
        let height = bounds.height / target
        zoom(to: CGRect(x: inCanvas.x - width / 2, y: inCanvas.y - height / 2, width: width, height: height), animated: true)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: canvas)
        let size = StoryMapGeometry.nodeSize
        let hit = nodes.first { node in
            let center = StoryMapGeometry.center(node)
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height).contains(point)
        }
        if let hit { open?(hit.entry) }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        zoom(by: zoomScale < 0.6 ? 2.2 : 0.45, at: recognizer.location(in: self))
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return canvas }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // A map smaller than the screen stays in the middle.
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // The lines are drawn again at the new size, so they stay sharp.
        let screenScale = window?.screen.scale ?? 3
        for layer in lineLayers { layer.contentsScale = screenScale * max(scale, 0.25) }
    }

    // MARK: Lines

    private func drawLines(_ map: UniverseStoryMap) {
        lineLayers.forEach { $0.removeFromSuperlayer() }
        lineLayers = []
        let byID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.entry.id, $0) })
        let half = StoryMapGeometry.nodeSize.width / 2 - 8
        let middle = StoryMapGeometry.posterMiddle
        func anchor(_ node: UniverseStoryMap.Node, right: Bool) -> CGPoint {
            let center = StoryMapGeometry.center(node)
            return CGPoint(x: center.x + (right ? half : -half), y: center.y + middle)
        }
        // The track of each storyline, faint, under everything.
        for lane in map.lanes {
            let slots = lane.entries.compactMap { byID[$0.id]?.slot }
            guard let low = slots.min(), let high = slots.max() else { continue }
            let start = StoryMapGeometry.center(slot: low, lane: lane.id)
            let end = StoryMapGeometry.center(slot: high, lane: lane.id)
            let track = UIBezierPath()
            track.move(to: CGPoint(x: start.x, y: start.y + middle))
            track.addLine(to: CGPoint(x: end.x, y: end.y + middle))
            addLayer(track, color: StoryMapGeometry.color(lane.id).withAlphaComponent(0.18), width: 16, dashed: false)
        }
        for lane in map.lanes {
            let sequels = UIBezierPath()
            let meetings = UIBezierPath()
            let heads = UIBezierPath()
            for link in map.links {
                guard let from = byID[link.from], let to = byID[link.to] else { continue }
                let owner = link.kind == .sequel ? from.lane : to.lane
                guard owner == lane.id else { continue }
                let start = anchor(from, right: true)
                let end = anchor(to, right: false)
                if link.kind == .sequel && from.lane == to.lane {
                    sequels.move(to: start)
                    sequels.addLine(to: end)
                } else {
                    let bend = max(40, abs(end.x - start.x) * 0.5)
                    meetings.move(to: start)
                    meetings.addCurve(to: end, controlPoint1: CGPoint(x: start.x + bend, y: start.y), controlPoint2: CGPoint(x: end.x - bend, y: end.y))
                    heads.move(to: end)
                    heads.addLine(to: CGPoint(x: end.x - 11, y: end.y - 7))
                    heads.addLine(to: CGPoint(x: end.x - 11, y: end.y + 7))
                    heads.close()
                }
            }
            let color = StoryMapGeometry.color(lane.id)
            if !sequels.isEmpty { addLayer(sequels, color: color.withAlphaComponent(0.95), width: 4.5, dashed: false) }
            if !meetings.isEmpty { addLayer(meetings, color: color.withAlphaComponent(0.8), width: 2.5, dashed: true) }
            if !heads.isEmpty { addLayer(heads, color: color, width: 0, dashed: false, filled: true) }
        }
    }

    private func addLayer(_ path: UIBezierPath, color: UIColor, width: CGFloat, dashed: Bool, filled: Bool = false) {
        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: contentSizeAtOne)
        layer.path = path.cgPath
        layer.fillColor = filled ? color.cgColor : UIColor.clear.cgColor
        layer.strokeColor = filled ? UIColor.clear.cgColor : color.cgColor
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        if dashed { layer.lineDashPattern = [8, 7] }
        layer.contentsScale = UIScreen.main.scale
        canvas.layer.addSublayer(layer)
        lineLayers.append(layer)
    }
}

/// Posters, names of the storylines and years, laid out once at zoom 1 over the lines.
struct StoryMapContent: View {
    let map: UniverseStoryMap
    let seen: Set<String>
    let showsYears: Bool
    let open: (UniverseEntry) -> Void

    var body: some View {
        let size = StoryMapGeometry.size(map)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)
            if showsYears { years }
            ForEach(map.lanes) { lane in laneLabel(lane) }
            ForEach(map.nodes) { node in
                nodeView(node, isWatched: seen.contains(node.id))
                    .position(StoryMapGeometry.center(node))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private struct YearMark: Identifiable {
        var year: Int
        var x: CGFloat
        var id: Int { return year }
    }

    private var years: some View {
        var shown: [YearMark] = []
        var lastYear: Int?
        for node in map.nodes.sorted(by: { $0.column < $1.column }) where node.entry.year != lastYear {
            lastYear = node.entry.year
            let x = StoryMapGeometry.center(node).x
            if let previous = shown.last, x - previous.x < 44 { continue }
            if shown.contains(where: { $0.year == node.entry.year }) { continue }
            shown.append(YearMark(year: node.entry.year, x: x))
        }
        return ZStack(alignment: .topLeading) {
            ForEach(shown) { item in
                Text(String(item.year))
                    .font(.system(size: 13, weight: .bold, design: AetherTypography.design))
                    .foregroundStyle(.white.opacity(0.55))
                    .position(x: item.x, y: 26)
            }
        }
    }

    /// The name of a storyline, at its start.
    private func laneLabel(_ lane: UniverseStoryMap.Lane) -> some View {
        let first = lane.entries.compactMap { entry in map.node(entry.id)?.slot }.min() ?? 0
        let start = StoryMapGeometry.center(slot: first, lane: lane.id)
        let color = Color(StoryMapGeometry.color(lane.id))
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(lane.name).font(.system(size: 14, weight: .bold, design: AetherTypography.design)).lineLimit(1)
            Text("\(lane.entries.count)").font(.system(size: 12, weight: .semibold, design: AetherTypography.design)).foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
        .fixedSize()
        .offset(x: max(6, start.x - StoryMapGeometry.slotWidth / 2), y: start.y - StoryMapGeometry.laneHeight / 2 - 4)
    }

    private func nodeView(_ node: UniverseStoryMap.Node, isWatched: Bool) -> some View {
        let entry = node.entry
        let color = Color(StoryMapGeometry.color(node.lane))
        return Button { open(entry) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(urlString: UniverseArt.poster(entry.id), width: 220, placeholderSeed: entry.name, systemPlaceholder: "film")
                        .frame(width: 84, height: 126)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isWatched ? Color.accentColor : color, lineWidth: isWatched ? 3 : 2))
                        .saturation(isWatched ? 1 : 0.85)
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Color.accentColor).offset(x: 7, y: -7)
                    } else if entry.isSeries {
                        Text("SERIE").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(color)).foregroundStyle(.white).offset(x: 4, y: -5)
                    }
                }
                Text(entry.name).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                    .foregroundStyle(.white).frame(width: StoryMapGeometry.nodeSize.width)
                Text(String(entry.year)).font(.system(size: 10, weight: .medium, design: AetherTypography.design)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: StoryMapGeometry.nodeSize.width, height: StoryMapGeometry.nodeSize.height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.name), \(String(entry.year))\(isWatched ? ", visto" : "")")
    }
}
