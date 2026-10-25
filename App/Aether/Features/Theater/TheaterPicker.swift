import SwiftUI
import AetherCore

/// The choice of the source in Theater Mode: the title on the left, the sources of the addons on the right, in the style of the mode.
/// It uses the same model as the normal sheet (ranking, TorBox checks, resolution), so the two can never disagree.
struct TheaterStreamPicker: View {
    let request: StreamPickerRequest
    let close: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @AppStorage(TheaterPrefs.corners) private var corners = 1
    @StateObject private var model: StreamPickerModel
    @State private var showUnplayable = false

    init(request: StreamPickerRequest, close: @escaping () -> Void) {
        self.request = request
        self.close = close
        _model = StateObject(wrappedValue: StreamPickerModel(request: request))
    }

    private var accent: Color { TheaterPalette.color(palette) }
    private var radius: CGFloat { [6, 14, 20][min(max(corners, 0), 2)] }

    var body: some View {
        ZStack {
            TheaterBackground()
            HStack(alignment: .top, spacing: 0) {
                sidebar.frame(width: 230)
                content
            }
            .padding(.leading, 6)
            if let info = model.infoMessage {
                VStack {
                    Spacer()
                    Text(info).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 18)
                }
                .task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    model.infoMessage = nil
                }
            }
        }
        .foregroundStyle(.white)
        .tint(accent)
        .preferredColorScheme(.dark)
        .alert("Impossibile completare", isPresented: Binding(get: { model.blockedMessage != nil }, set: { if !$0 { model.blockedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.blockedMessage ?? "")
        }
        .confirmationDialog(DebridUserText.downloadConfirmationTitle,
                            isPresented: Binding(get: { model.pendingDownload != nil }, set: { if !$0 { model.pendingDownload = nil } }),
                            titleVisibility: .visible,
                            presenting: model.pendingDownload) { (pending: RankedStream) in
            Button("Avvia il download") { model.confirmDownload(pending, env: env) { close() } }
            Button("Annulla", role: .cancel) {}
        } message: { (_: RankedStream) in
            Text(DebridUserText.downloadConfirmationMessage)
        }
        // The page of the player opens at once while TorBox is contacted: the film's logo (with a fanart.tv key) or its title.
        .fullScreenCover(isPresented: Binding(get: { model.resolution != nil }, set: { if !$0 { model.cancelResolution() } })) {
            PlaybackPreparingView(meta: request.meta, resolution: model.resolution) { model.cancelResolution() }
                .environmentObject(env)
        }
        .sheet(item: $model.fileChoice) { (choice: DebridFileChoice) in
            DebridFileChoiceSheet(choice: choice) { (file: DebridFileCandidate) in
                model.chooseFile(file, from: choice, env: env) { close() }
            }
        }
        .onAppear {
            model.start(env: env) { best in
                Task { await model.play(best, env: env) { close() } }
            }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Left column

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: close) {
                Label("Indietro", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityIdentifier("theater.picker.close")
            Spacer(minLength: 0)
            RemoteImage(urlString: request.meta.poster ?? request.meta.background, width: 260, placeholderSeed: request.meta.name)
                .frame(width: 108, height: 162)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(accent.opacity(0.6), lineWidth: 1))
                .shadow(color: accent.opacity(0.35), radius: 14, y: 6)
            Text(request.meta.name).font(.system(.headline, design: .serif).weight(.bold)).lineLimit(3)
            if let video = request.video, let label = video.episodeLabel {
                Text("\(label) · \(video.title)").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
            }
            if let resume = request.resumeAt, resume > 0 {
                Text("Riprende da \(Format.duration(resume))").font(.caption).foregroundStyle(accent)
            }
        }
        .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Right column

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("SCEGLI LA SORGENTE").font(.caption2.weight(.bold)).tracking(4).foregroundStyle(accent).padding(.top, 14)
                if model.addonNames.count > 1 { chips }
                if let failure = model.cacheCheckFailure, model.hasTorrentRows { cacheNotice(failure) }
                let playable = model.filtered(model.playable)
                ForEach(Array(playable.enumerated()), id: \.element.id) { offset, item in
                    streamEntry(offset: offset, item: item)
                }
                if model.isLoading {
                    HStack(spacing: 12) {
                        ProgressView().tint(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playable.isEmpty ? "Cerco sorgenti…" : "Altre sorgenti in arrivo…").font(.subheadline.weight(.medium))
                            if !model.pendingAddons.isEmpty {
                                Text("In attesa di: \(model.pendingAddons.joined(separator: ", "))").font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("stream.loading")
                } else if model.ranked.isEmpty {
                    emptyState
                }
                unplayableSection
                errorsSection
                Color.clear.frame(height: 20)
            }
            .padding(.trailing, 28).padding(.leading, 8)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Tutti", selected: model.addonFilter == nil) { model.addonFilter = nil }
                ForEach(model.addonNames, id: \.self) { name in
                    chip(name, selected: model.addonFilter == name) { model.addonFilter = name }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? accent : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(selected ? Color.black : .white)
        }
    }

    @ViewBuilder
    private func streamEntry(offset: Int, item: RankedStream) -> some View {
        let isTorrent = DebridStreamLogic.isTorrent(item.stream)
        HStack(alignment: .top, spacing: 8) {
            StreamRow(item: item, isBest: offset == 0, debrid: model.appearance(for: item)) {
                Task { await model.play(item, env: env) { close() } }
            }
            .accessibilityIdentifier("stream.row.\(offset)")
            if !isTorrent {
                Button { Task { await model.download(item, env: env) } } label: {
                    Image(systemName: "arrow.down.circle").font(.title3).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Scarica per guardarlo offline")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(offset == 0 ? accent.opacity(0.7) : .white.opacity(0.1), lineWidth: offset == 0 ? 1.4 : 1))
        .contextMenu {
            Button { Task { await model.play(item, env: env) { close() } } } label: { Label("Riproduci", systemImage: "play.fill") }
            if !isTorrent {
                Button { Task { await model.download(item, env: env) } } label: {
                    Label("Scarica per guardarlo offline", systemImage: "arrow.down.circle")
                }
            }
        }
        if model.resolution?.itemID == item.id, let state = model.resolution {
            DebridProgressRow(state: state) { model.cancelResolution() }.padding(.horizontal, 12)
        }
        if model.rowFailure?.itemID == item.id, let failure = model.rowFailure {
            DebridFailureRow(failure: failure) { model.retryResolution(env: env) { close() } }.padding(.horizontal, 12)
        }
    }

    private func cacheNotice(_ failure: DebridError) -> some View {
        let text = "Non riesco a controllare la cache di TorBox. " + DebridErrorText.message(for: failure)
        let retryAction: (() -> Void)? = failure.isRetryable ? { () -> Void in model.retryCacheCheck() } : nil
        return DebridCacheNotice(message: text, retry: retryAction).padding(.horizontal, -Theme.pageMargin)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            Text("Nessuna sorgente trovata").font(.headline)
            Text(env.addons.enabledAddons.isEmpty ? "Non c'è nessun addon attivo." : "Gli addon attivi non hanno restituito sorgenti per questo titolo. Prova un altro addon o riprova più tardi.")
                .font(.footnote).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
            Button("Riprova") { model.start(env: env) { _ in } }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .accessibilityIdentifier("stream.empty")
    }

    @ViewBuilder
    private var unplayableSection: some View {
        let unplayable = model.filtered(model.unplayable)
        if !unplayable.isEmpty {
            DisclosureGroup("Non riproducibili su iOS (\(unplayable.count))", isExpanded: $showUnplayable) {
                ForEach(unplayable) { item in
                    Button {
                        if case .unsupported(let reason) = item.info.support { model.blockedMessage = reason.message }
                        else if case .torrent = item.stream.source { model.blockedMessage = DebridUserText.torrentNeedsTorBox }
                    } label: {
                        Text(item.stream.name ?? "Sorgente").font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                }
            }
            .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private var errorsSection: some View {
        if !model.errors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Addon con problemi").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                ForEach(model.errors.keys.sorted(), id: \.self) { name in
                    Text("\(name): \(model.errors[name]?.message ?? "")").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}
