import SwiftUI
import AVFoundation
import AetherCore

struct PlayerView: View {
    @StateObject private var model: PlayerViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var volume = SystemVolume()
    @State private var controlsVisible = true
    @State private var isLocked = false
    @State private var showUnlockHint = false
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var sheet: PlayerSheet?
    @State private var importingSubtitle = false
    @State private var hud: HUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var dragMode: DragMode?
    @State private var dragStart: Double = 0
    @State private var seekPreview: Double?
    @State private var originalBrightness: Double = 0.5
    @State private var castNotice: CastNotice?
    @State private var pendingCast: PendingCast?

    private enum DragMode { case brightness, volume, seek }

    struct HUD: Equatable {
        var icon: String
        var text: String
        var fraction: Double?
    }

    struct CastNotice: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    struct PendingCast: Identifiable {
        let id = UUID()
        var device: CastDevice
        var warnings: [String]
    }

    init(request: PlayerRequest, env: AppEnvironment) {
        _model = StateObject(wrappedValue: PlayerViewModel(request: request, env: env))
    }

    private var playbackSettings: PlaybackSettings { settings.value.playback }
    private var isCasting: Bool { casting.session != nil }

    var body: some View {
        reactions
            .onChange(of: sheet) { _, value in sheetChanged(value) }
            .onChange(of: remotePosition) { _, value in remotePositionChanged(value) }
            .accessibilityAction(.escape) { close() }
    }

    private var reactions: some View {
        lifecycle
            .onChange(of: network.reconnectToken) { _, _ in networkChanged() }
            .onChange(of: model.snapshot.isPlaying) { _, value in playingChanged(value) }
            .onChange(of: model.didFinish) { _, value in finishedChanged(value) }
    }

    private var lifecycle: some View {
        presented
            .onAppear(perform: appear)
            .onDisappear(perform: disappear)
            .onChange(of: scenePhase) { _, phase in scenePhaseChanged(phase) }
    }

    private func scenePhaseChanged(_ phase: ScenePhase) {
        model.scenePhaseChanged(isActive: phase == .active)
    }

    private func networkChanged() {
        model.networkChanged(isOnline: network.isOnline)
    }

    private func playingChanged(_ playing: Bool) {
        if playing { scheduleHide() } else { showControls() }
    }

    private func finishedChanged(_ finished: Bool) {
        if finished { close() }
    }

    private func sheetChanged(_ value: PlayerSheet?) {
        if value == nil { scheduleHide() } else { hideTask?.cancel() }
    }

    private func remotePositionChanged(_ position: Double?) {
        guard let position = position, let session = casting.session else { return }
        model.remoteProgress(position: position, duration: session.status.duration)
    }

    private var remotePosition: Double? { casting.session?.status.position }

    private var presented: some View {
        stage
            .background(Color.black)
            .statusBarHidden(!controlsVisible || isLocked)
            .persistentSystemOverlays(.hidden)
            .preferredColorScheme(.dark)
            .sheet(item: $sheet) { sheet in sheetContent(sheet) }
            .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: SubtitleFileTypes.all) { result in
                if case .success(let url) = result { model.importLocalSubtitle(url) }
            }
            .alert(castNotice?.title ?? "", isPresented: castNoticeBinding, presenting: castNotice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            .confirmationDialog(pendingCast.map { "Trasmettere a «\($0.device.name)»?" } ?? "",
                                isPresented: pendingCastBinding, titleVisibility: .visible, presenting: pendingCast) { pending in
                Button("Invia comunque") { performCast(to: pending.device) }
                Button("Annulla", role: .cancel) {}
            } message: { pending in
                Text(pending.warnings.joined(separator: "\n\n"))
            }
    }

    private var castNoticeBinding: Binding<Bool> {
        Binding(get: { castNotice != nil }, set: { if !$0 { castNotice = nil } })
    }

    private var pendingCastBinding: Binding<Bool> {
        Binding(get: { pendingCast != nil }, set: { if !$0 { pendingCast = nil } })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .tracks: PlayerTracksSheet(model: model, onImport: { importingSubtitle = true })
        case .episodes: PlayerEpisodesSheet(model: model)
        case .info: PlayerInfoSheet(model: model)
        case .sources: PlayerSourcesSheet(model: model)
        case .cast: PlayerCastSheet(onSelect: { prepareCast(to: $0) })
        }
    }

    private var stage: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                PlayerSurface(engine: model.engine)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                HiddenVolumeView(controller: volume).frame(width: 1, height: 1).allowsHitTesting(false)

                subtitleOverlay(size: proxy.size)

                gestureLayer(size: proxy.size)

                if controlsVisible && !isLocked && model.failure == nil && !isCasting {
                    controlsOverlay
                        .transition(.opacity)
                }
                if isLocked { lockOverlay }
                if showsCenterSpinner {
                    ProgressView().controlSize(.large).tint(.white)
                }
                overlays(size: proxy.size)
            }
            .animation(animationsAllowed ? .easeInOut(duration: 0.2) : nil, value: controlsVisible)
        }
    }

    private var animationsAllowed: Bool { !reduceMotion && settings.animationsEnabled }

    private var showsCenterSpinner: Bool {
        model.snapshot.isBuffering && !isCasting && model.failure == nil && (!controlsVisible || isLocked)
    }

    // MARK: Lifecycle

    private func appear() {
        originalBrightness = ScreenBrightness.value
        OrientationController.set(playbackSettings.landscapeOnly ? .landscape : .allButUpsideDown)
        model.start()
        casting.onRemoteSessionEnded = { position, reason in
            model.castDidEnd(position: position, resumeLocally: settings.value.casting.resumeLocallyOnDisconnect)
            if let reason = reason {
                castNotice = CastNotice(title: "Trasmissione interrotta", message: reason)
            }
        }
        scheduleHide()
    }

    private func disappear() {
        hideTask?.cancel()
        hudTask?.cancel()
        casting.onRemoteSessionEnded = nil
        if casting.session != nil { casting.stop() }
        model.teardown()
        ScreenBrightness.value = originalBrightness
        OrientationController.set(.portrait)
    }

    private func close() {
        router.player = nil
    }

    // MARK: Controls visibility

    private func showControls() {
        withAnimation { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.snapshot.isPlaying, !isScrubbing, sheet == nil, !isCasting else { return }
        let delay = Double(playbackSettings.controlsAutoHideSeconds)
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }

    private func toggleControls() {
        if isLocked {
            showUnlockHint = true
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                showUnlockHint = false
            }
            return
        }
        if controlsVisible { withAnimation { controlsVisible = false } } else { showControls() }
    }

    // MARK: Subtitles

    private func subtitleOverlay(size: CGSize) -> some View {
        let style = playbackSettings.subtitleStyle
        let scale = max(0.8, min(1.9, min(size.width, size.height) / 390))
        let lift = controlsVisible && !isLocked ? 90 : 0
        return VStack {
            Spacer()
            if !model.activeCues.isEmpty && !isCasting {
                SubtitleText(text: model.activeCues.map { $0.text }.joined(separator: "\n"), style: style, scale: scale)
                    .frame(maxWidth: size.width * 0.85)
                    .padding(.bottom, size.height * CGFloat(style.bottomOffsetPercent / 100) + CGFloat(lift))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: controlsVisible)
    }

    // MARK: Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in doubleTap(at: value.location, width: size.width) }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in toggleControls() })
            )
            .simultaneousGesture(dragGesture(size: size))
            .accessibilityHidden(true)
    }

    private func doubleTap(at location: CGPoint, width: CGFloat) {
        guard !isLocked, playbackSettings.gesturesEnabled else { return }
        if location.x < width * 0.35 {
            model.skipBack()
            flash(HUD(icon: skipSymbol(seconds: playbackSettings.skipBackSeconds, forward: false), text: "−\(playbackSettings.skipBackSeconds) s"))
        } else if location.x > width * 0.65 {
            model.skipForward()
            flash(HUD(icon: skipSymbol(seconds: playbackSettings.skipForwardSeconds, forward: true), text: "+\(playbackSettings.skipForwardSeconds) s"))
        } else {
            model.togglePlayPause()
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard playbackSettings.gesturesEnabled, !isLocked, !isCasting else { return }
                if dragMode == nil {
                    let vertical = abs(value.translation.height) > abs(value.translation.width)
                    if vertical {
                        if value.startLocation.x < size.width / 2 {
                            dragMode = .brightness
                            dragStart = ScreenBrightness.value
                        } else {
                            dragMode = .volume
                            dragStart = volume.value
                        }
                    } else if model.snapshot.duration > 0 && !model.snapshot.isLive {
                        dragMode = .seek
                        dragStart = model.snapshot.position
                    } else {
                        return
                    }
                }
                switch dragMode {
                case .brightness:
                    let level = min(1, max(0, dragStart - Double(value.translation.height / size.height) * 1.3))
                    ScreenBrightness.value = level
                    hud = HUD(icon: "sun.max.fill", text: "\(Int(level * 100))%", fraction: level)
                case .volume:
                    let level = min(1, max(0, dragStart - Double(value.translation.height / size.height) * 1.3))
                    volume.set(level)
                    hud = HUD(icon: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", text: "\(Int(level * 100))%", fraction: level)
                case .seek:
                    let delta = Double(value.translation.width / size.width) * 120
                    let target = min(max(0, dragStart + delta), model.snapshot.duration)
                    seekPreview = target
                    hud = HUD(icon: delta >= 0 ? "forward.fill" : "backward.fill",
                              text: "\(Format.duration(target))  (\(delta >= 0 ? "+" : "−")\(Int(abs(target - dragStart))) s)", fraction: nil)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if dragMode == .seek, let target = seekPreview { model.seek(to: target) }
                dragMode = nil
                seekPreview = nil
                hudTask?.cancel()
                hudTask = Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if !Task.isCancelled { hud = nil }
                }
            }
    }

    private func flash(_ value: HUD) {
        hud = value
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { hud = nil }
        }
    }

    // MARK: Controls

    private var controlsOverlay: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            centerControls
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassIconButton(systemName: "chevron.down", accessibilityLabel: "Chiudi il player") { close() }
                .accessibilityIdentifier("player.close")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1)
                if let subtitle = model.episodeSubtitle(), !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            AetherGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    if let remaining = model.sleepRemaining {
                        Text(Format.duration(remaining))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 10).frame(height: 44)
                            .aetherGlassCapsule()
                            .accessibilityLabel("Timer di spegnimento: \(Format.duration(remaining))")
                    }
                    AirPlayRoutePicker(tint: .white, activeTint: UIColor(settings.accentColor))
                        .frame(width: 44, height: 44)
                        .aetherGlass(in: Circle(), interactive: true)
                    GlassIconButton(systemName: "tv.and.mediabox", accessibilityLabel: "Trasmetti su Google Cast o DLNA") {
                        sheet = .cast
                    }
                    .accessibilityIdentifier("player.cast")
                    if model.supportsPictureInPicture {
                        GlassIconButton(systemName: "pip.enter", accessibilityLabel: "Picture in Picture") { model.startPictureInPicture() }
                    }
                    GlassIconButton(systemName: "captions.bubble", accessibilityLabel: "Audio e sottotitoli") { sheet = .tracks }
                        .accessibilityIdentifier("player.tracks")
                    moreMenu
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Menu {
                Picker("Velocità", selection: Binding(get: { model.playbackRate }, set: { model.setRate($0) })) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                        Text(rateLabel(rate)).tag(rate)
                    }
                }
            } label: { Label("Velocità (\(rateLabel(model.playbackRate)))", systemImage: "speedometer") }
            Menu {
                Button("Disattivato") { model.setSleepTimer(minutes: nil) }
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) minuti") { model.setSleepTimer(minutes: minutes) }
                }
            } label: { Label("Timer di spegnimento", systemImage: "moon.zzz") }
            Button {
                model.toggleFill()
            } label: {
                Label(model.isFill ? "Adatta allo schermo" : "Riempi lo schermo", systemImage: model.isFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            if !model.alternatives.isEmpty {
                Button { sheet = .sources } label: { Label("Cambia sorgente", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button { importingSubtitle = true } label: { Label("Importa sottotitoli…", systemImage: "doc.badge.plus") }
            Button { sheet = .info } label: { Label("Informazioni sulla sorgente", systemImage: "info.circle") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .aetherGlass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("Altre opzioni")
        .accessibilityIdentifier("player.more")
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "Normale" : String(format: "%.2g×", Double(rate))
    }

    private var centerControls: some View {
        AetherGlassGroup(spacing: 24) {
            HStack(spacing: 34) {
                if model.previousEpisode != nil {
                    Button { Task { await model.playPrevious() } } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: 24))
                    }
                    .accessibilityLabel("Episodio precedente")
                }
                Button { model.skipBack(); showControls() } label: {
                    Image(systemName: skipSymbol(seconds: playbackSettings.skipBackSeconds, forward: false)).font(.system(size: 30))
                }
                .accessibilityLabel("Indietro di \(playbackSettings.skipBackSeconds) secondi")
                Button { model.togglePlayPause(); showControls() } label: {
                    ZStack {
                        if model.snapshot.isBuffering && !model.snapshot.isPlaying {
                            ProgressView().controlSize(.large).tint(.white)
                        } else {
                            Image(systemName: model.snapshot.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34))
                        }
                    }
                    .frame(width: 78, height: 78)
                    .aetherGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(model.snapshot.isPlaying ? "Pausa" : "Riproduci")
                .accessibilityIdentifier("player.playPause")
                Button { model.skipForward(); showControls() } label: {
                    Image(systemName: skipSymbol(seconds: playbackSettings.skipForwardSeconds, forward: true)).font(.system(size: 30))
                }
                .accessibilityLabel("Avanti di \(playbackSettings.skipForwardSeconds) secondi")
                if model.nextEpisode != nil {
                    Button { Task { await model.playNext() } } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: 24))
                    }
                    .accessibilityLabel("Episodio successivo")
                    .accessibilityIdentifier("player.next")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        let snapshot = model.snapshot
        let position = seekPreview ?? snapshot.position
        return VStack(spacing: 4) {
            if snapshot.isLive {
                HStack {
                    Label("IN DIRETTA", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.85), in: Capsule())
                    Spacer()
                }
            } else {
                PlayerScrubber(position: position, duration: snapshot.duration, buffered: snapshot.bufferedPosition,
                               accent: settings.accentColor,
                               onEditingChanged: { editing in
                                   isScrubbing = editing
                                   if editing { hideTask?.cancel() } else { scheduleHide() }
                               },
                               onSeek: { model.seek(to: $0) })
                HStack {
                    Text(Format.duration(position))
                    Spacer()
                    Text("−" + Format.duration(max(0, snapshot.duration - position)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                bottomButton("lock.fill", "Blocca i controlli") { isLocked = true; withAnimation { controlsVisible = false } }
                if model.playbackRate != 1 {
                    Text(rateLabel(model.playbackRate))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).frame(height: 34)
                        .aetherGlassCapsule()
                }
                if let route = model.airPlayRoute {
                    Label(route, systemImage: "airplayvideo").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 34).aetherGlassCapsule()
                }
                Spacer()
                if model.meta.videos.count > 1 && model.currentVideo != nil {
                    Button { sheet = .episodes } label: {
                        Label("Episodi", systemImage: "list.bullet").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 36)
                            .aetherGlassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.episodes")
                }
            }
        }
    }

    private func bottomButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .aetherGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var lockOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if showUnlockHint {
                    Button { isLocked = false; showControls() } label: {
                        Label("Sblocca", systemImage: "lock.open.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).frame(height: 44)
                            .aetherGlassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.unlock")
                }
            }
            Spacer()
        }
        .padding(20)
        .foregroundStyle(.white)
    }

    // MARK: Overlays (HUD, errors, next episode, casting)

    @ViewBuilder
    private func overlays(size: CGSize) -> some View {
        if let hud = hud {
            VStack(spacing: 8) {
                Image(systemName: hud.icon).font(.system(size: 26, weight: .semibold))
                Text(hud.text).font(.subheadline.monospacedDigit().weight(.semibold))
                if let fraction = hud.fraction {
                    ProgressView(value: fraction).frame(width: 110).tint(.white)
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .aetherGlassCard(cornerRadius: 22)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        VStack {
            if let message = model.statusMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .aetherGlassCapsule()
                    .foregroundStyle(.white)
                    .padding(.top, 14)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        .allowsHitTesting(false)

        if let failure = model.failure {
            failurePanel(failure)
        }

        if model.failure == nil, !isCasting, let next = model.nextEpisode, shouldShowNextCard {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    nextEpisodeCard(next)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, controlsVisible ? 120 : 30)
        }

        if let session = casting.session {
            castingOverlay(session)
        }
    }

    private var shouldShowNextCard: Bool {
        if model.nextCountdown != nil || model.isResolvingNext { return true }
        let snapshot = model.snapshot
        guard snapshot.duration > 120, !snapshot.isLive else { return false }
        return snapshot.duration - snapshot.position < 45
    }

    private func nextEpisodeCard(_ next: Video) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prossimo episodio").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
            Text([next.episodeLabel, next.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold)).lineLimit(2)
            if model.isResolvingNext {
                HStack(spacing: 8) { ProgressView().tint(.white); Text("Cerco la sorgente…").font(.footnote) }
            } else if let seconds = model.nextCountdown {
                Text("Parte tra \(seconds) s").font(.footnote.monospacedDigit())
            }
            HStack(spacing: 10) {
                Button { Task { await model.playNext() } } label: {
                    Text("Riproduci ora").font(.footnote.weight(.bold)).padding(.horizontal, 14).frame(height: 34)
                        .background(settings.accentColor, in: Capsule())
                }
                .accessibilityIdentifier("player.playNextNow")
                if model.nextCountdown != nil {
                    Button { model.cancelCountdown() } label: {
                        Text("Annulla").font(.footnote.weight(.semibold)).padding(.horizontal, 14).frame(height: 34)
                            .aetherGlassCapsule(interactive: true)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 300, alignment: .leading)
        .aetherGlassCard(cornerRadius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.nextEpisodeCard")
    }

    private func failurePanel(_ failure: PlaybackFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text("Impossibile riprodurre").font(.headline)
            Text(failure.message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
            if settings.value.advanced.verboseLogging, !failure.detail.isEmpty {
                Text(failure.detail).font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 10) {
                Button { model.retry() } label: { Label("Riprova", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .accessibilityIdentifier("player.retry")
                if model.alternatives.contains(where: { $0.info.support.isPlayable }) {
                    Button { sheet = .sources } label: { Text("Altra sorgente") }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("player.otherSource")
                }
                Button { close() } label: { Text("Chiudi") }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 440)
        .aetherGlassCard(cornerRadius: 28)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.error")
    }

    private func castingOverlay(_ session: CastCoordinator.Session) -> some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "tv.and.mediabox.fill").font(.system(size: 44)).foregroundStyle(settings.accentColor)
                Text("Riproduzione su \(session.device.name)").font(.title3.weight(.semibold))
                CastSessionControls()
                    .padding(16)
                    .aetherGlassCard(cornerRadius: 22)
                Button { casting.stop() } label: { Label("Torna a guardare sul telefono", systemImage: "iphone") }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 460)
            .padding(24)
            VStack {
                HStack {
                    GlassIconButton(systemName: "chevron.down", accessibilityLabel: "Chiudi il player") { close() }
                    Spacer()
                }
                Spacer()
            }
            .padding(20)
        }
        .accessibilityIdentifier("player.castingOverlay")
    }

    // MARK: Casting

    private func prepareCast(to device: CastDevice) {
        guard let plan = model.castPlan() else {
            castNotice = CastNotice(title: "Non trasmettibile",
                                    message: "I file scaricati si trovano solo su questo telefono: il televisore non può leggerli. Usa AirPlay, oppure trasmetti la sorgente online.")
            return
        }
        let verdict = CastCompatibility.evaluate(url: plan.media.url, info: plan.info, headers: plan.headers,
                                                 target: device.target, hasExternalSubtitles: model.externalSubtitleCount() > 0)
        switch verdict {
        case .blocked(let message):
            castNotice = CastNotice(title: "Questa sorgente non può essere trasmessa", message: message)
        case .warning(let messages):
            pendingCast = PendingCast(device: device, warnings: messages)
        case .ok:
            performCast(to: device)
        }
    }

    private func performCast(to device: CastDevice) {
        guard var plan = model.castPlan() else { return }
        plan.media.startPosition = model.snapshot.position
        let position = model.snapshot.position
        Task {
            do {
                try await casting.cast(plan.media, to: device, localPosition: position)
                model.castDidStart()
            } catch {
                castNotice = CastNotice(title: "Trasmissione non riuscita", message: error.localizedDescription)
            }
        }
    }
}
