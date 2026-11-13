import SwiftUI
import AetherCore

private enum PickerEntry: Identifiable {
    case stream(offset: Int, item: RankedStream)
    case progress(itemID: String)
    case failure(itemID: String)

    var id: String {
        switch self {
        case .stream(_, let item): return "stream:" + item.id
        case .progress(let itemID): return "progress:" + itemID
        case .failure(let itemID): return "failure:" + itemID
        }
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
    @State private var packItem: RankedStream?
    /// The film's logo (fanart.tv), in place of its name where there is one.
    @State private var logo: UIImage?
    /// Where the logo is in the header, on screen: the flight to the player starts there.
    @State private var logoFrame: CGRect = .zero
    @State private var flight: LogoFlight = .idle
    /// The source just touched: it lights up and the others step back while the logo flies to the player.
    @State private var chosenID: String?

    /// The logo leaving the list for the player: it grows, turns with the screen and the list goes black, while the source is prepared.
    enum LogoFlight { case idle, lifted, landed }

    init(request: StreamPickerRequest) {
        self.request = request
        _model = StateObject(wrappedValue: StreamPickerModel(request: request))
        _logo = State(initialValue: FanartLogoStore.shared.cached(request.meta.id))
    }

    /// Starts the source and, at the same moment, the flight of the logo: the work (the debrid service, the link, the conversion)
    /// does not wait for the animation, only the black page does.
    private func launch(_ item: RankedStream) {
        let flies = settings.animationsEnabled && flight == .idle && logoFrame.width > 0
        if settings.animationsEnabled {
            Haptics.tap()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { chosenID = item.id }
            // A source that does not go to the player (a question, a file to pick, an error) gives the list back as it was.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if !model.usesLaunchPage { withAnimation(.easeOut(duration: 0.2)) { chosenID = nil } }
            }
        }
        if flies {
            model.launchHold = 0.62
            flight = .landed
            LogoFlightAnimator.fly(image: logo, title: request.meta.name, from: logoFrame)
            // A source that asks something first (a download to confirm, a file to choose) or that could not start brings the list back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !model.usesLaunchPage { land(back: true) }
            }
            // Once the player's page is over it, the black and the logo of the flight are no longer needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if model.usesLaunchPage { LogoFlightAnimator.land(animated: false) }
            }
        }
        Task { await model.play(item, env: env) { dismiss() } }
    }

    private func land(back: Bool) {
        guard back, flight != .idle else { return }
        model.launchHold = 0
        LogoFlightAnimator.land(animated: true)
        withAnimation(.easeInOut(duration: 0.35)) { flight = .idle }
    }

    var body: some View {
        NavigationStack {
            List {
                header
                    // The player's page left and the list is back (a failure, the player closed): no source stays lit.
                    .onChange(of: model.usesLaunchPage) { _, uses in if !uses { chosenID = nil } }
                    .listRowBackground(Color.clear)
                if model.addonNames.count > 1 {
                    Section { chips }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if settings.value.appearance.streamQuickFilters, hasQuickChoices {
                    Section { quickChips }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if let failure = model.cacheCheckFailure, model.hasTorrentRows, model.debridProvider == .torbox {
                    Section { cacheNotice(failure) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                let playable = model.filtered(model.playable)
                if !playable.isEmpty {
                    Section(header: Text("Sorgenti riproducibili")) {
                        ForEach(entries(for: playable)) { entry in
                            entryRow(entry)
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
                        // While nothing has arrived yet, the shape of the rows to come instead of an empty list.
                        if playable.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in SkeletonSourceRow() }
                        }
                    }
                } else if model.ranked.isEmpty || (!model.isLoading && model.debridProvider == .realdebrid && model.debridConfigured && model.playable.isEmpty) {
                    Section { emptyState }
                }
                let unplayable = model.filtered(model.unplayable)
                if !unplayable.isEmpty {
                    Section {
                        DisclosureGroup("Non riproducibili su iOS (\(unplayable.count))", isExpanded: $showUnplayable) {
                            ForEach(unplayable) { item in
                                StreamRow(item: item, isBest: false, debrid: model.appearance(for: item)) { openExternally(item) }
                                    .contextMenu {
                                        copyLinkButton(item)
                                        externalPlayerMenu(item)
                                    }
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
            .scrollContentBackground(.hidden)
            .background { backdrop }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("Scegli la sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Cerca tra le sorgenti (nome, qualità, lingua…)")
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
        .environment(\.colorScheme, .dark)
        .presentationDetents([.large])
        .sheet(item: $packItem) { item in
            PackDownloadSheet(item: item, meta: model.request.meta, video: model.request.video)
        }
        .confirmationDialog(DebridUserText.downloadConfirmationTitle,
                            isPresented: Binding(get: { model.pendingDownload != nil }, set: { if !$0 { model.pendingDownload = nil } }),
                            titleVisibility: .visible,
                            presenting: model.pendingDownload) { (pending: RankedStream) in
            Button("Avvia il download") { model.confirmDownload(pending, env: env) { dismiss() } }
            Button("Annulla", role: .cancel) {}
        } message: { (_: RankedStream) in
            Text(DebridUserText.downloadConfirmationMessage)
        }
        // The page of the player opens at once while TorBox is contacted: the film's logo (with a fanart.tv key) or its title.
        .fullScreenCover(isPresented: Binding(get: { model.resolution != nil && !model.usesLaunchPage }, set: { if !$0 { model.cancelResolution() } })) {
            PlaybackPreparingView(meta: request.meta, resolution: model.resolution) { model.cancelResolution() }
                .environmentObject(env)
        }
        .sheet(item: $model.fileChoice) { (choice: DebridFileChoice) in
            DebridFileChoiceSheet(choice: choice) { (file: DebridFileCandidate) in
                model.chooseFile(file, from: choice, env: env) { dismiss() }
            }
        }
        .onAppear {
            model.start(env: env) { best in launch(best) }
        }
        .onChange(of: model.usesLaunchPage) { _, launched in
            // The page was taken down (the source could not be played, or the wait was cancelled): the list comes back.
            if !launched { land(back: true) }
        }
        .task {
            if logo == nil { logo = await FanartLogoStore.shared.load(meta: request.meta, env: env) }
        }
        .onDisappear {
            LogoFlightAnimator.land(animated: false)
            model.stop()
        }
    }

    /// The film's scene behind the list, blurred and dark.
    private var backdrop: some View {
        ZStack {
            Color(red: 0.04, green: 0.045, blue: 0.07)
            RemoteImage(urlString: request.meta.background ?? request.meta.poster, width: 900, placeholderSeed: request.meta.name)
                .blur(radius: 28)
                .opacity(0.55)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    /// The logo, or the name in big letters where the film has no logo.
    @ViewBuilder
    private var mark: some View {
        if let logo = logo {
            Image(uiImage: logo).resizable().scaledToFit()
                .frame(maxWidth: 250, maxHeight: 92)
                .shadow(color: .black.opacity(0.6), radius: 10)
                .accessibilityLabel(request.meta.name)
        } else {
            Text(request.meta.name)
                .font(.aetherTitle(28))
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .frame(maxWidth: 300)
        }
    }

    private func entries(for list: [RankedStream]) -> [PickerEntry] {
        var result: [PickerEntry] = []
        for (offset, item) in list.enumerated() {
            result.append(PickerEntry.stream(offset: offset, item: item))
            if model.resolution?.itemID == item.id, !model.usesLaunchPage { result.append(PickerEntry.progress(itemID: item.id)) }
            if model.rowFailure?.itemID == item.id { result.append(PickerEntry.failure(itemID: item.id)) }
        }
        return result
    }

    @ViewBuilder
    private func entryRow(_ entry: PickerEntry) -> some View {
        switch entry {
        case .stream(let offset, let item):
            streamRow(offset: offset, item: item)
        case .progress:
            if let state = model.resolution {
                DebridProgressRow(state: state) { model.cancelResolution() }
            }
        case .failure:
            if let failure = model.rowFailure {
                DebridFailureRow(failure: failure) { model.retryResolution(env: env) { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func streamRow(offset: Int, item: RankedStream) -> some View {
        StreamRow(item: item, isBest: offset == 0, debrid: model.appearance(for: item)) {
            launch(item)
        }
        .listRowBackground(Color.white.opacity(offset == 0 ? 0.11 : 0.06))
        .opacity(chosenID != nil && chosenID != item.id ? 0.35 : 1)
        .scaleEffect(chosenID == item.id ? 1.02 : 1)
        .overlay {
            if chosenID == item.id {
                RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-6)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("stream.row.\(offset)")
        .swipeActions(edge: .trailing) {
            Button { Task { await model.download(item, env: env) } } label: {
                Label("Scarica", systemImage: "arrow.down.circle")
            }
            .tint(settings.accentColor)
        }
        .contextMenu {
            Button { launch(item) } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            Button { Task { await model.download(item, env: env) } } label: {
                Label("Scarica per guardarlo offline", systemImage: "arrow.down.circle")
            }
            if DebridStreamLogic.isTorrent(item.stream), model.request.meta.type == "series" {
                Button { packItem = item } label: {
                    Label("Scarica più episodi del pack…", systemImage: "arrow.down.square.stack")
                }
            }
            copyLinkButton(item)
            externalPlayerMenu(item)
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                mark
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { logoFrame = $0 }
                    .opacity(flight == .idle ? 1 : 0)
                if let video = model.request.video, let label = video.episodeLabel {
                    Text("\(label) · \(video.title)").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                let facts = [model.request.meta.releaseInfo, model.request.meta.runtime].compactMap { $0 }.filter { !$0.isEmpty }
                HStack(spacing: 8) {
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · ")).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    if let resume = model.request.resumeAt, resume > 0 {
                        Label("Riprende da \(Format.duration(resume))", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(settings.accentColor.opacity(0.25)))
                            .foregroundStyle(.white)
                    }
                }
                if !model.playable.isEmpty {
                    Text(model.playable.count == 1 ? "1 sorgente pronta" : "\(model.playable.count) sorgenti pronte")
                        .font(.caption2.weight(.bold)).textCase(.uppercase).tracking(1.1).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
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

    private var hasQuickChoices: Bool {
        let all = model.ranked
        return StreamQuickFilter.qualities(in: all).count > 1 || StreamQuickFilter.languages(in: all).count > 1
            || StreamQuickFilter.hasHDR(in: all) || model.quickFilter.isActive
    }

    /// Quality, HDR and language: each chip narrows the list; tapping it again (or «Tutte») clears it.
    private var quickChips: some View {
        let all = model.ranked
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                FilterChip(title: "Tutte", isSelected: !model.quickFilter.isActive) { model.quickFilter = StreamQuickFilter() }
                ForEach(StreamQuickFilter.qualities(in: all), id: \.self) { quality in
                    FilterChip(title: quality.label, isSelected: model.quickFilter.quality == quality) {
                        model.quickFilter.quality = model.quickFilter.quality == quality ? nil : quality
                    }
                }
                if StreamQuickFilter.hasHDR(in: all) {
                    FilterChip(title: "HDR", isSelected: model.quickFilter.hdrOnly) { model.quickFilter.hdrOnly.toggle() }
                }
                ForEach(StreamQuickFilter.languages(in: all), id: \.self) { language in
                    FilterChip(title: language, isSelected: model.quickFilter.language == language) {
                        model.quickFilter.language = model.quickFilter.language == language ? nil : language
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("stream.quickFilters")
    }

    /// The cache check failed: the torrent rows carry no badge, and this says why (with a retry when trying again can help).
    private func cacheNotice(_ failure: DebridError) -> some View {
        let provider = model.debridProvider.title
        let text: String = "Non riesco a controllare la cache di \(provider). " +
            DebridErrorText.message(for: failure, provider: model.debridProvider)
        let retryAction: (() -> Void)? = failure.isRetryable ? { () -> Void in model.retryCacheCheck() } : nil
        return DebridCacheNotice(message: text, retry: retryAction)
    }

    @ViewBuilder
    private var emptyState: some View {
        let handles = env.addons.enabledAddons
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Color.aetherSecondary)
            Text("Nessuna sorgente trovata").font(.headline)
            Text(handles.isEmpty ? "Non c'è nessun addon attivo." : (model.debridProvider == .realdebrid && model.debridConfigured
                ? "Gli addon attivi non hanno restituito sorgenti torrent utilizzabili con Real-Debrid per questo titolo."
                : "Gli addon attivi non hanno restituito sorgenti per questo titolo. Prova un altro addon o riprova più tardi."))
                .font(.footnote).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            Button("Riprova") { model.start(env: env) { _ in } }.buttonStyle(SecondaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityIdentifier("stream.empty")
    }

    /// «Copia il link» for any source, whatever it is (direct link, web page, torrent as a magnet, YouTube, live channel).
    @ViewBuilder
    private func copyLinkButton(_ item: RankedStream) -> some View {
        if let link = item.stream.shareableLink {
            Button {
                UIPasteboard.general.string = link
                if case .torrent = item.stream.source { model.infoMessage = "Magnet copiato" } else { model.infoMessage = "Link copiato" }
            } label: {
                Label("Copia il link", systemImage: "link")
            }
            if DebridStreamLogic.isTorrent(item.stream) {
                Button {
                    Task {
                        if let address = await model.playbackLink(item, env: env) {
                            UIPasteboard.general.string = address.absoluteString
                            model.infoMessage = "Link di riproduzione copiato. Contiene il tuo accesso al servizio e scade: non condividerlo."
                        }
                    }
                } label: {
                    Label("Copia il link di riproduzione (via debrid)", systemImage: "link.badge.plus")
                }
            }
        }
    }

    /// «Apri in un lettore esterno»: VLC, Infuse, nPlayer, Outplayer (solo quelli installati), per le fonti con un indirizzo diretto
    /// e per i torrent (il link lo fa il servizio debrid configurato).
    @ViewBuilder
    private func externalPlayerMenu(_ item: RankedStream) -> some View {
        if item.stream.directMediaURL != nil || DebridStreamLogic.isTorrent(item.stream) {
            let installed = ExternalPlayer.allCases.filter { (player: ExternalPlayer) -> Bool in
                guard let probe = player.probeURL else { return false }
                return UIApplication.shared.canOpenURL(probe)
            }
            let live = env.settings.value.playback
            Menu {
                if !live.liveContainerBundleID.isEmpty {
                    Button {
                        Task {
                            guard let media = await model.playbackLink(item, env: env) else { return }
                            if let address = LiveContainerLauncher.url(scheme: live.liveContainerScheme, bundleID: live.liveContainerBundleID,
                                                                       media: media, player: live.liveContainerPlayer) {
                                openURL(address)
                            } else {
                                model.blockedMessage = "Controlla le impostazioni di LiveContainer (id dell'app e schema)."
                            }
                        }
                    } label: {
                        Text("LiveContainer · \(live.liveContainerPlayer.title)")
                    }
                }
                if installed.isEmpty && live.liveContainerBundleID.isEmpty {
                    Text("Nessun lettore esterno installato (VLC, Infuse, nPlayer, Outplayer)")
                } else {
                    ForEach(installed, id: \.self) { player in
                        Button {
                            Task {
                                if let address = await model.externalPlayerURL(item, player: player, env: env) { openURL(address) }
                                if item.stream.needsRequestHeaders {
                                    model.infoMessage = "Questa fonte richiede intestazioni particolari: il lettore esterno potrebbe riceverne un 403."
                                }
                            }
                        } label: {
                            Text(player.title)
                        }
                    }
                }
            } label: {
                Label("Apri in un lettore esterno", systemImage: "arrow.up.forward.app")
            }
        }
    }

    private func openExternally(_ item: RankedStream) {
        switch item.stream.source {
        case .youtube(let id):
            if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { openURL(url) }
        case .external(let string):
            if let url = URL.lenient(string), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" { openURL(url) }
        case .torrent:
            model.blockedMessage = DebridUserText.torrentNeedsTorBox
        default:
            // Nothing to open: say why instead of ignoring the tap.
            if case .unsupported(let reason) = item.info.support { model.blockedMessage = reason.message }
        }
    }
}
