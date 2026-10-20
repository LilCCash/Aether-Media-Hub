import SwiftUI
import AetherCore

struct StreamPickerRequest: Identifiable {
    let id = UUID()
    var meta: MetaItem
    var video: Video?
    var resumeAt: Double?
}

extension AppEnvironment {
    /// Stream ranking preferences derived from settings and the user's addon order.
    func streamPreferences() -> StreamPreferences {
        let value = settings.value
        var server: URL?
        if value.advanced.useExternalStreamingServer {
            let trimmed = value.advanced.streamingServerURL.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                server = url
            }
        }
        return StreamPreferences(
            qualityCap: value.playback.qualityCap,
            preferredLanguage: SettingsStore.resolvedLanguage(value.playback.preferredAudioLanguage),
            preferLanguage: value.playback.preferStreamsInPreferredAudioLanguage,
            addonOrder: addons.addons.map { $0.id.uuidString },
            streamingServer: server,
            capabilities: PlaybackEngineFactory.capabilities)
    }

    func bingeGroup(forMeta metaID: String) -> String? {
        return UserDefaults.standard.string(forKey: "aether.binge.\(metaID)")
    }

    func setBingeGroup(_ group: String?, forMeta metaID: String) {
        if let group = group, !group.isEmpty {
            UserDefaults.standard.set(group, forKey: "aether.binge.\(metaID)")
        } else {
            UserDefaults.standard.removeObject(forKey: "aether.binge.\(metaID)")
        }
    }

    /// Validates the media URL against the network policy (local-network opt-in, loopback…) before playback/cast.
    func validateMediaURL(_ url: URL) async -> AddonError? {
        let policy = settings.snapshot.get().networkPolicy(allowLoopback: isUITesting)
        do {
            try await policy.validate(url, purpose: .mediaPlayback)
            return nil
        } catch let error as AddonError {
            return error
        } catch {
            return nil
        }
    }
}

@MainActor
final class StreamPickerModel: ObservableObject {
    @Published private(set) var ranked: [RankedStream] = []
    @Published private(set) var errors: [String: AddonError] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var pendingAddons: [String] = []
    @Published var addonFilter: String?
    @Published var blockedMessage: String?
    @Published var infoMessage: String?

    private var collected: [AddonStream] = []
    private var seen = Set<String>()
    private var task: Task<Void, Never>?
    private(set) var request: StreamPickerRequest
    private weak var env: AppEnvironment?
    private var autoSelected = false

    init(request: StreamPickerRequest) {
        self.request = request
    }

    deinit {
        task?.cancel()
    }

    var playable: [RankedStream] { ranked.filter { $0.info.support.isPlayable } }
    var unplayable: [RankedStream] { ranked.filter { !$0.info.support.isPlayable } }

    var addonNames: [String] {
        var names: [String] = []
        for item in ranked {
            if let name = item.stream.addonName, !names.contains(name) { names.append(name) }
        }
        return names
    }

    func filtered(_ list: [RankedStream]) -> [RankedStream] {
        guard let filter = addonFilter else { return list }
        return list.filter { $0.stream.addonName == filter }
    }

    func start(env: AppEnvironment, onAutoSelect: @escaping (RankedStream) -> Void) {
        self.env = env
        task?.cancel()
        collected = []
        seen = []
        errors = [:]
        isLoading = true
        task = Task { [weak self] in
            await self?.run(onAutoSelect: onAutoSelect)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func run(onAutoSelect: @escaping (RankedStream) -> Void) async {
        guard let env = env else { return }
        let videoID = request.video?.id ?? request.meta.id
        let type = request.meta.type

        if let embedded = request.video?.streams, !embedded.isEmpty {
            // The meta response carried its own streams: Stremio does not ask other addons in that case.
            ingest(embedded)
            isLoading = false
            maybeAutoSelect(env: env, onAutoSelect: onAutoSelect)
            return
        }

        let path = ResourcePath(resource: ResourceName.stream, type: type, id: videoID)
        let handles = await env.addons.handles()
        pendingAddons = RequestPlanner.addons(for: path, handles: handles).map { $0.addon.displayName }
        if pendingAddons.isEmpty {
            isLoading = false
            return
        }
        for await batch in env.service.streams(type: type, videoID: videoID) {
            if Task.isCancelled { return }
            pendingAddons.removeAll(where: { $0 == batch.addonName })
            if let error = batch.error { errors[batch.addonName] = error }
            ingest(batch.streams)
        }
        if Task.isCancelled { return }
        isLoading = false
        pendingAddons = []
        maybeAutoSelect(env: env, onAutoSelect: onAutoSelect)
    }

    private func ingest(_ streams: [AddonStream]) {
        guard let env = env else { return }
        for stream in streams where seen.insert(stream.id).inserted {
            collected.append(stream)
        }
        ranked = StreamSelector.rank(collected, preferences: env.streamPreferences())
    }

    private func maybeAutoSelect(env: AppEnvironment, onAutoSelect: @escaping (RankedStream) -> Void) {
        guard !autoSelected, env.settings.value.playback.autoSelectStream else { return }
        // Continuity: prefer the release group of the previous episode of this series.
        let binge = env.bingeGroup(forMeta: request.meta.id)
        guard let best = StreamSelector.autoSelect(ranked, previousBingeGroup: binge) else { return }
        autoSelected = true
        onAutoSelect(best)
    }

    /// Queues the file for offline viewing. Only direct files qualify; the planner explains refusals.
    func download(_ item: RankedStream, env: AppEnvironment) async {
        let allowLocal = env.settings.value.privacy.allowLocalNetwork
        if let refusal = await env.downloads.enqueue(meta: request.meta, video: request.video, stream: item.stream, allowLocalNetwork: allowLocal) {
            blockedMessage = refusal
        } else {
            infoMessage = "Download avviato. Lo trovi in Libreria ▸ Download."
        }
    }

    func play(_ item: RankedStream, env: AppEnvironment, dismiss: () -> Void) async {
        if let url = StreamResolver.playbackURL(for: item.stream, streamingServer: env.streamPreferences().streamingServer) {
            if let blocked = await env.validateMediaURL(url) {
                blockedMessage = blocked.message
                return
            }
        } else {
            blockedMessage = "Questa sorgente non può essere riprodotta."
            return
        }
        env.setBingeGroup(item.stream.behaviorHints.bingeGroup, forMeta: request.meta.id)
        let alternatives = playable.filter { $0.id != item.id }
        let player = PlayerRequest(meta: request.meta, video: request.video, source: .stream(item.stream), alternatives: alternatives)
        dismiss()
        // Present after the sheet is gone to avoid overlapping presentations.
        try? await Task.sleep(nanoseconds: 350_000_000)
        env.router.play(player)
    }
}

struct StreamPickerSheet: View {
    let request: StreamPickerRequest
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model: StreamPickerModel
    @State private var showUnplayable = false

    init(request: StreamPickerRequest) {
        self.request = request
        _model = StateObject(wrappedValue: StreamPickerModel(request: request))
    }

    var body: some View {
        NavigationStack {
            List {
                header
                if model.addonNames.count > 1 {
                    Section { chips }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                let playable = model.filtered(model.playable)
                if !playable.isEmpty {
                    Section(header: Text("Sorgenti riproducibili")) {
                        ForEach(Array(playable.enumerated()), id: \.element.id) { offset, item in
                            StreamRow(item: item, isBest: offset == 0) {
                                Task { await model.play(item, env: env) { dismiss() } }
                            }
                            .accessibilityIdentifier("stream.row.\(offset)")
                            .swipeActions(edge: .trailing) {
                                Button { Task { await model.download(item, env: env) } } label: {
                                    Label("Scarica", systemImage: "arrow.down.circle")
                                }
                                .tint(settings.accentColor)
                            }
                            .contextMenu {
                                Button { Task { await model.play(item, env: env) { dismiss() } } } label: {
                                    Label("Riproduci", systemImage: "play.fill")
                                }
                                Button { Task { await model.download(item, env: env) } } label: {
                                    Label("Scarica per guardarlo offline", systemImage: "arrow.down.circle")
                                }
                            }
                        }
                    }
                }
                if model.isLoading {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playable.isEmpty ? "Cerco sorgenti…" : "Altre sorgenti in arrivo…").font(.subheadline.weight(.medium))
                                if !model.pendingAddons.isEmpty {
                                    Text("In attesa di: \(model.pendingAddons.joined(separator: ", "))").font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("stream.loading")
                    }
                } else if model.ranked.isEmpty {
                    Section { emptyState }
                }
                let unplayable = model.filtered(model.unplayable)
                if !unplayable.isEmpty {
                    Section {
                        DisclosureGroup("Non riproducibili su iOS (\(unplayable.count))", isExpanded: $showUnplayable) {
                            ForEach(unplayable) { item in
                                StreamRow(item: item, isBest: false) { openExternally(item) }
                            }
                        }
                    }
                }
                if !model.errors.isEmpty {
                    Section(header: Text("Addon con problemi")) {
                        ForEach(model.errors.keys.sorted(), id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.subheadline.weight(.semibold))
                                Text(model.errors[name]?.message ?? "").font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Scegli la sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .alert("Impossibile completare", isPresented: Binding(get: { model.blockedMessage != nil }, set: { if !$0 { model.blockedMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.blockedMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let info = model.infoMessage {
                    Text(info)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .aetherGlassCapsule()
                        .padding(.bottom, 20)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            model.infoMessage = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.infoMessage)
        }
        .presentationDetents([.large])
        .onAppear {
            model.start(env: env) { best in
                Task { await model.play(best, env: env) { dismiss() } }
            }
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                RemoteImage(urlString: model.request.meta.poster, width: 120, placeholderSeed: model.request.meta.name)
                    .frame(width: 52, height: 77)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.request.meta.name).font(.headline).lineLimit(2)
                    if let video = model.request.video, let label = video.episodeLabel {
                        Text("\(label) · \(video.title)").font(.subheadline).foregroundStyle(Color.aetherSecondary).lineLimit(2)
                    }
                    if let resume = model.request.resumeAt, resume > 0 {
                        Text("Riprende da \(Format.duration(resume))").font(.caption).foregroundStyle(settings.accentColor)
                    }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                FilterChip(title: "Tutti", isSelected: model.addonFilter == nil) { model.addonFilter = nil }
                ForEach(model.addonNames, id: \.self) { name in
                    FilterChip(title: name, isSelected: model.addonFilter == name) { model.addonFilter = name }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let handles = env.addons.enabledAddons
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Color.aetherSecondary)
            Text("Nessuna sorgente trovata").font(.headline)
            Text(handles.isEmpty ? "Non c'è nessun addon attivo." : "Gli addon attivi non hanno restituito sorgenti per questo titolo. Prova un altro addon o riprova più tardi.")
                .font(.footnote).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            Button("Riprova") { model.start(env: env) { _ in } }.buttonStyle(SecondaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityIdentifier("stream.empty")
    }

    private func openExternally(_ item: RankedStream) {
        switch item.stream.source {
        case .youtube(let id):
            if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { openURL(url) }
        case .external(let string):
            if let url = URL.lenient(string), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" { openURL(url) }
        default:
            break
        }
    }
}

struct StreamRow: View {
    let item: RankedStream
    let isBest: Bool
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    if isBest {
                        Label("Consigliata", systemImage: "sparkles")
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                            .foregroundStyle(settings.accentColor)
                    }
                    Spacer()
                    if let addon = item.stream.addonName {
                        Text(addon).font(.caption2).foregroundStyle(Color.aetherSecondary)
                    }
                }
                Text(item.stream.name ?? "Sorgente")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let details = item.stream.details, !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(3)
                }
                FlowBadges(info: item.info)
                if case .unsupported(let reason) = item.info.support {
                    Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.info.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(Color.aetherSecondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.info.support.isPlayable ? "Riproduci questa sorgente" : "Non riproducibile")
    }
}

/// Wrapping row of small badges (quality, codec, HDR, audio, languages, size).
struct FlowBadges: View {
    let info: StreamInfo

    var body: some View {
        let badges = info.badges
            + info.languages.map { LanguageCodes.displayName($0) }
            + [info.sizeLabel].compactMap { $0 }
            + [info.kind == .hls ? "HLS" : nil, info.container?.uppercased()].compactMap { $0 }
        if !badges.isEmpty {
            WrappingHStack(spacing: 6) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                }
            }
        }
    }
}

/// Minimal flow layout (iOS 16+ `Layout`).
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
