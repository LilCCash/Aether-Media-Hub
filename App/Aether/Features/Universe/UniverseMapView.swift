import SwiftUI
import AetherCore

/// The universe as a map of its stories: every line is a storyline (Iron Man, the Skywalker saga, Bond's Connery years…), the titles
/// sit on it from left to right in the chosen order, a line joins the next title of the same story, and the curves show where stories
/// meet. It is explored like a map: pinch to zoom out for the whole universe or in for the titles, drag to move, double tap to zoom.
struct UniverseMapView: View {
    let universe: UniverseDefinition
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var order: UniverseOrder = .release

    // The view of the map: content point p is drawn at p · scale + offset.
    @State private var scale: CGFloat = 0.6
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var pinchStart: (scale: CGFloat, offset: CGSize)?
    @State private var viewport: CGSize = .zero
    @State private var placed = false

    // Content geometry (points at scale 1).
    private let slotWidth: CGFloat = 128
    private let laneHeight: CGFloat = 196
    private let leftPad: CGFloat = 40
    private let topPad: CGFloat = 56
    private let nodeSize = CGSize(width: 110, height: 176)
    private let maxScale: CGFloat = 1.3

    private var custom: [String]? { return settings.value.content.universes.customOrders[universe.id] }
    private var watched: Set<String> { return Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys) }
    private var orders: [UniverseOrder] { return universe.chronological == nil ? [.release] : [.release, .chronological] }

    var body: some View {
        let map = UniverseStoryMap.build(universe, order: order, custom: custom)
        let seen = watched
        return NavigationStack {
            ZStack {
                Color(red: 0.035, green: 0.04, blue: 0.07).ignoresSafeArea()
                GeometryReader { proxy in
                    canvas(map, seen: seen)
                        .onAppear { viewportChanged(proxy.size, map: map) }
                        .onChange(of: proxy.size) { _, size in viewportChanged(size, map: map) }
                }
                .clipped()
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
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
            .onChange(of: order) { _, _ in
                withAnimation(.smooth(duration: 0.45)) { place(UniverseStoryMap.build(universe, order: order, custom: custom), overview: false) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Geometry

    private func contentSize(_ map: UniverseStoryMap) -> CGSize {
        return CGSize(width: leftPad * 2 + CGFloat(max(1, map.slotCount)) * slotWidth,
                      height: topPad + CGFloat(max(1, map.lanes.count)) * laneHeight + 70)
    }

    private func point(_ node: UniverseStoryMap.Node) -> CGPoint {
        return CGPoint(x: leftPad + (CGFloat(node.slot) + 0.5) * slotWidth, y: topPad + (CGFloat(node.lane) + 0.5) * laneHeight)
    }

    private func screen(_ p: CGPoint) -> CGPoint {
        return CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height)
    }

    private func minScale(_ map: UniverseStoryMap) -> CGFloat {
        guard viewport.width > 0 else { return 0.05 }
        let size = contentSize(map)
        return max(0.03, min(0.5, min(viewport.width / size.width, viewport.height / size.height) * 0.95))
    }

    private func viewportChanged(_ size: CGSize, map: UniverseStoryMap) {
        viewport = size
        if !placed {
            placed = true
            place(map, overview: false)
        } else {
            offset = clamped(offset, scale: scale, map: map)
        }
    }

    /// The start of the map, big enough to read the titles (or the whole universe, `overview`).
    private func place(_ map: UniverseStoryMap, overview: Bool) {
        let size = contentSize(map)
        if overview {
            scale = minScale(map)
        } else {
            // Up to four lines on screen, never smaller than the titles can be read.
            let fitLanes = viewport.height / (topPad + laneHeight * CGFloat(min(4, max(1, map.lanes.count))) + 20)
            scale = min(maxScale, max(0.42, fitLanes))
        }
        let first = map.nodes.first.map(point) ?? CGPoint(x: leftPad, y: topPad)
        var target = CGSize(width: 20 - (first.x - slotWidth / 2) * scale, height: 46)
        if size.width * scale < viewport.width { target.width = (viewport.width - size.width * scale) / 2 }
        offset = clamped(target, scale: scale, map: map)
    }

    private func clamped(_ value: CGSize, scale: CGFloat, map: UniverseStoryMap) -> CGSize {
        let size = contentSize(map)
        func axis(_ v: CGFloat, content: CGFloat, view: CGFloat, leading: CGFloat) -> CGFloat {
            let drawn = content * scale
            if drawn + leading < view { return leading + (view - leading - drawn) / 2 }
            return min(leading + 40, max(view - drawn - 80, v))
        }
        return CGSize(width: axis(value.width, content: size.width, view: viewport.width, leading: 0),
                      height: axis(value.height, content: size.height, view: viewport.height, leading: 40))
    }

    // MARK: Drawing

    private func canvas(_ map: UniverseStoryMap, seen: Set<String>) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.entry.id, $0) })
        let detailed = scale >= 0.3
        let margin = max(nodeSize.width, nodeSize.height) * scale
        let visible = map.nodes.filter { node in
            let p = screen(point(node))
            return p.x > -margin && p.x < viewport.width + margin && p.y > -margin && p.y < viewport.height + margin
        }
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawLanes(map, in: &context)
                drawYears(map, in: &context)
                for link in map.links {
                    guard let from = byID[link.from], let to = byID[link.to] else { continue }
                    drawLink(link, from: from, to: to, in: &context)
                }
                if !detailed {
                    for node in map.nodes {
                        let p = screen(point(node))
                        let radius = max(3, 26 * scale)
                        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(seen.contains(node.id) ? Color.accentColor : laneColor(node.lane)))
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.8)), lineWidth: 1.2)
                    }
                }
            }
            .allowsHitTesting(false)
            if detailed {
                ForEach(visible) { node in
                    nodeView(node, isWatched: seen.contains(node.id))
                        .scaleEffect(scale)
                        .position(screen(point(node)))
                }
            }
            laneLabels(map)
        }
        .frame(width: viewport.width, height: viewport.height)
        .contentShape(Rectangle())
        .gesture(panAndZoom(map))
        .onTapGesture(count: 2) { location in zoom(by: scale < 0.6 ? 2.2 : 0.45, around: location, map: map) }
    }

    private func drawLanes(_ map: UniverseStoryMap, in context: inout GraphicsContext) {
        for lane in map.lanes {
            let y = topPad + (CGFloat(lane.id) + 0.5) * laneHeight
            // The lane's band, faint, and the track from its first title to its last.
            let band = CGRect(x: 0, y: (y - laneHeight / 2) * scale + offset.height, width: viewport.width, height: laneHeight * scale)
            if lane.id % 2 == 0 { context.fill(Path(band), with: .color(.white.opacity(0.025))) }
            let slots = lane.entries.compactMap { map.node($0.id)?.slot }
            guard let low = slots.min(), let high = slots.max() else { continue }
            let start = screen(CGPoint(x: leftPad + (CGFloat(low) + 0.5) * slotWidth, y: y))
            let end = screen(CGPoint(x: leftPad + (CGFloat(high) + 0.5) * slotWidth, y: y))
            var track = Path()
            track.move(to: start)
            track.addLine(to: end)
            context.stroke(track, with: .color(laneColor(lane.id).opacity(0.22)), style: StrokeStyle(lineWidth: max(2, 10 * scale), lineCap: .round))
        }
    }

    private func drawYears(_ map: UniverseStoryMap, in context: inout GraphicsContext) {
        guard order == .release else { return }
        var lastYear: Int?
        var lastX = -CGFloat.infinity
        for node in map.nodes.sorted(by: { $0.column < $1.column }) where node.entry.year != lastYear {
            lastYear = node.entry.year
            let x = screen(point(node)).x
            guard x - lastX > 34 else { continue }
            lastX = x
            let top = max(52, offset.height + topPad * scale - 24)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: top + 10))
            tick.addLine(to: CGPoint(x: x, y: viewport.height))
            context.stroke(tick, with: .color(.white.opacity(0.05)), lineWidth: 1)
            context.draw(Text(String(node.entry.year)).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.55)),
                         at: CGPoint(x: x, y: top))
        }
    }

    private func drawLink(_ link: UniverseStoryMap.Link, from: UniverseStoryMap.Node, to: UniverseStoryMap.Node, in context: inout GraphicsContext) {
        let a = screen(point(from))
        let b = screen(point(to))
        let half = nodeSize.width / 2 * scale * 0.8
        let start = CGPoint(x: a.x + half, y: a.y)
        let end = CGPoint(x: b.x - half, y: b.y)
        var path = Path()
        path.move(to: start)
        if link.kind == .sequel && from.lane == to.lane {
            path.addLine(to: end)
        } else {
            let bend = max(30 * scale, abs(end.x - start.x) * 0.5)
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        }
        let color = laneColor(link.kind == .sequel ? from.lane : to.lane)
        if link.kind == .sequel {
            context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.5, 4 * scale), lineCap: .round))
        } else {
            let dash = max(scale, 0.4)
            context.stroke(path, with: .color(color.opacity(0.75)),
                           style: StrokeStyle(lineWidth: max(1, 2.5 * scale), lineCap: .round, dash: [6 * dash, 5 * dash]))
            // An arrow head where the story arrives.
            let size = max(4, 9 * scale)
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - size, y: end.y - size * 0.6))
            head.addLine(to: CGPoint(x: end.x - size, y: end.y + size * 0.6))
            head.closeSubpath()
            context.fill(head, with: .color(color.opacity(0.9)))
        }
    }

    /// The names of the lines stay on the left edge, wherever the map is moved.
    private func laneLabels(_ map: UniverseStoryMap) -> some View {
        ForEach(map.lanes) { lane in
            let y = (topPad + CGFloat(lane.id) * laneHeight) * scale + offset.height + 4
            if y > 40 && y < viewport.height - 20 {
                HStack(spacing: 6) {
                    Circle().fill(laneColor(lane.id)).frame(width: 8, height: 8)
                    Text(lane.name).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
                    Text("\(lane.entries.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(laneColor(lane.id).opacity(0.5), lineWidth: 1))
                .fixedSize()
                .offset(x: 10, y: y)
                .allowsHitTesting(false)
            }
        }
    }

    private func nodeView(_ node: UniverseStoryMap.Node, isWatched: Bool) -> some View {
        let entry = node.entry
        let color = laneColor(node.lane)
        let route = MetaRoute(type: entry.type, id: entry.id,
                              preview: MetaItem(id: entry.id, type: entry.type, name: entry.name, poster: UniverseArt.poster(entry.id)))
        return NavigationLink(value: route) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(urlString: UniverseArt.poster(entry.id), width: 220, placeholderSeed: entry.name, systemPlaceholder: "film")
                        .frame(width: 84, height: 126)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isWatched ? Color.accentColor : color, lineWidth: isWatched ? 3 : 2))
                        .shadow(color: color.opacity(0.45), radius: 10, y: 3)
                        .saturation(isWatched ? 1 : 0.85)
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Color.accentColor).offset(x: 7, y: -7)
                    } else if entry.isSeries {
                        Text("SERIE").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(color)).foregroundStyle(.white).offset(x: 4, y: -5)
                    }
                }
                Text(entry.name).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                    .foregroundStyle(.white).frame(width: nodeSize.width)
                Text(String(entry.year)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: nodeSize.width, height: nodeSize.height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(entry.name), \(String(entry.year))\(isWatched ? ", visto" : "")")
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
            mapButton("minus.magnifyingglass", label: "Allontana") { zoom(by: 0.6, around: center, map: map) }
            mapButton("plus.magnifyingglass", label: "Avvicina") { zoom(by: 1.6, around: center, map: map) }
            mapButton("arrow.up.left.and.arrow.down.right", label: "Tutto l'universo") {
                withAnimation(.smooth(duration: 0.45)) { place(map, overview: scale > minScale(map) * 1.2) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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

    // MARK: Gestures

    private var center: CGPoint { return CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

    private func zoom(by factor: CGFloat, around location: CGPoint, map: UniverseStoryMap) {
        let target = min(maxScale, max(minScale(map), scale * factor))
        let ratio = target / scale
        let moved = CGSize(width: location.x - (location.x - offset.width) * ratio, height: location.y - (location.y - offset.height) * ratio)
        withAnimation(.smooth(duration: 0.35)) {
            scale = target
            offset = clamped(moved, scale: target, map: map)
        }
    }

    private func panAndZoom(_ map: UniverseStoryMap) -> some Gesture {
        let pan = DragGesture(minimumDistance: 6)
            .onChanged { value in
                // Two fingers belong to the pinch, which moves the map itself.
                guard pinchStart == nil else { return }
                if panStart == nil { panStart = offset }
                let start = panStart ?? offset
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { value in
                guard let start = panStart else { return }
                panStart = nil
                // The map keeps sliding a little, as a map does.
                let flung = CGSize(width: start.width + value.predictedEndTranslation.width, height: start.height + value.predictedEndTranslation.height)
                withAnimation(.interpolatingSpring(mass: 1, stiffness: 90, damping: 20)) { offset = clamped(flung, scale: scale, map: map) }
            }
        let pinch = MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = (scale, offset); panStart = nil }
                guard let start = pinchStart else { return }
                let target = min(maxScale * 1.15, max(minScale(map) * 0.85, start.scale * value.magnification))
                let ratio = target / start.scale
                let anchor = value.startLocation
                scale = target
                offset = CGSize(width: anchor.x - (anchor.x - start.offset.width) * ratio, height: anchor.y - (anchor.y - start.offset.height) * ratio)
            }
            .onEnded { _ in
                pinchStart = nil
                withAnimation(.smooth(duration: 0.3)) {
                    scale = min(maxScale, max(minScale(map), scale))
                    offset = clamped(offset, scale: scale, map: map)
                }
            }
        return pinch.simultaneously(with: pan)
    }

    // MARK: Colours

    private static let palette: [Color] = [
        Color(red: 0.95, green: 0.27, blue: 0.27), Color(red: 0.98, green: 0.62, blue: 0.18), Color(red: 0.25, green: 0.56, blue: 0.98),
        Color(red: 0.62, green: 0.40, blue: 0.98), Color(red: 0.20, green: 0.80, blue: 0.55), Color(red: 0.98, green: 0.80, blue: 0.20),
        Color(red: 0.95, green: 0.38, blue: 0.70), Color(red: 0.30, green: 0.82, blue: 0.90), Color(red: 0.70, green: 0.85, blue: 0.30),
        Color(red: 0.85, green: 0.55, blue: 0.40), Color(red: 0.55, green: 0.65, blue: 0.95), Color(red: 0.90, green: 0.45, blue: 0.95),
    ]

    private func laneColor(_ lane: Int) -> Color { return UniverseMapView.palette[lane % UniverseMapView.palette.count] }
}
