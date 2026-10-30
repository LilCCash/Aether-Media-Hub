import SwiftUI
import AetherCore

struct MoreView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var router: AppRouter
    @State private var path = NavigationPath()

    enum Destination: Hashable { case addons, stats, casting, settings, about }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Destination.addons) {
                        rowLabel("Addon", "puzzlepiece.extension.fill", .indigo,
                                 detail: addons.addons.isEmpty ? "Nessuno" : "\(addons.enabledAddons.count) attivi")
                    }
                    .accessibilityIdentifier("more.addons")
                    NavigationLink(value: Destination.stats) {
                        rowLabel("Statistiche", "chart.bar.fill", .orange, detail: nil)
                    }
                    .accessibilityIdentifier("more.stats")
                    NavigationLink(value: Destination.casting) {
                        rowLabel("Casting", "tv.and.mediabox.fill", .teal, detail: casting.statusSummary)
                    }
                    .accessibilityIdentifier("more.casting")
                }
                Section {
                    NavigationLink(value: Destination.settings) {
                        rowLabel("Impostazioni", "gearshape.fill", .gray, detail: nil)
                    }
                    .accessibilityIdentifier("more.settings")
                    NavigationLink(value: Destination.about) {
                        rowLabel("Informazioni e licenze", "info.circle.fill", .blue, detail: nil)
                    }
                    .accessibilityIdentifier("more.about")
                }
            }
            .navigationTitle("Altro")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .addons: AddonsView()
                case .stats: StatsView()
                case .casting: CastView()
                case .settings: SettingsRootView()
                case .about: AboutView()
                }
            }
            .onChange(of: router.pendingAddonInput) { _, input in
                if input != nil && path.isEmpty { path.append(Destination.addons) }
            }
            .onAppear {
                if router.pendingAddonInput != nil && path.isEmpty { path.append(Destination.addons) }
            }
        }
    }

    private func rowLabel(_ title: String, _ icon: String, _ color: Color, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
            Spacer()
            if let detail = detail { Text(detail).font(.footnote).foregroundStyle(Color.aetherSecondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsRootView: View {
    var body: some View {
        List {
            Section {
                link("Aspetto", "paintpalette.fill", .pink) { AppearanceSettingsView() }
                link("Theater Mode", "film.stack.fill", .yellow) { TheaterSettingsView() }
                link("Riproduzione", "play.rectangle.fill", .orange) { PlaybackSettingsView() }
                link("Contenuti e scoperta", "square.grid.2x2.fill", .green) { ContentSettingsView() }
                link("Casting", "tv.and.mediabox.fill", .teal) { CastingSettingsView() }
                link("Servizi", "key.fill", .purple) { ServicesSettingsView() }
            }
            Section {
                link("Archiviazione", "internaldrive.fill", .brown) { StorageSettingsView() }
                link("Account e dati", "person.crop.circle.fill", .blue) { AccountDataSettingsView() }
                link("Avanzate", "wrench.and.screwdriver.fill", .gray) { AdvancedSettingsView() }
            }
        }
        .navigationTitle("Impostazioni")
        .accessibilityIdentifier("settings.root")
    }

    private func link<Destination: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
            }
        }
        .accessibilityIdentifier("settings.\(title)")
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            Section(header: Text("Tema")) {
                Picker("Tema", selection: settings.binding(\.appearance.theme)) {
                    ForEach(ThemeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.theme")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Colore d'accento")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(AccentChoice.allCases, id: \.self) { choice in
                            Button {
                                settings.value.appearance.accent = choice
                            } label: {
                                Circle().fill(Theme.accent(for: choice).gradient)
                                    .frame(width: 38, height: 38)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: settings.value.appearance.accent == choice ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.title)
                            .accessibilityAddTraits(settings.value.appearance.accent == choice ? .isSelected : [])
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section(header: Text("Stile dell'app"),
                    footer: Text("Colori, sfondo e atmosfera, più le modalità Dynamic Cinematic UI e AMOLED.")) {
                NavigationLink {
                    StyleSettingsView()
                } label: {
                    Label("Stile e grafica", systemImage: "sparkles")
                }
                .accessibilityIdentifier("settings.style")
            }
            Section(header: Text("Home"),
                    footer: Text("Sezioni e carosello della Home, dimensione e densità delle schede. Nomi e ordine dei cataloghi sono in Contenuti e scoperta; badge e formato delle sorgenti in Riproduzione.")) {
                NavigationLink {
                    HomeLayoutSettingsView()
                } label: {
                    Label("Personalizza la Home", systemImage: "rectangle.3.group")
                }
                .accessibilityIdentifier("settings.homeLayout")
                Picker("Dimensione delle schede", selection: settings.binding(\.appearance.posterSize)) {
                    ForEach(PosterSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Densità", selection: settings.binding(\.appearance.density)) {
                    ForEach(CatalogDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(header: Text("Effetti"), footer: Text("Con gli effetti ridotti il vetro liquido viene sostituito da superfici opache e lo sfondo diventa uniforme. Aether rispetta anche «Riduci trasparenza» e «Riduci movimento» di iOS.")) {
                Toggle("Animazioni", isOn: settings.binding(\.appearance.animationsEnabled))
                Toggle("Riduci gli effetti visivi", isOn: settings.binding(\.appearance.reduceVisualEffects))
                    .accessibilityIdentifier("settings.reduceEffects")
            }
        }
        .navigationTitle("Aspetto")
    }
}

// MARK: - Playback

struct PlaybackSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private static let languages: [(String, String)] = [
        ("it", "Italiano"), ("en", "Inglese"), ("fr", "Francese"), ("es", "Spagnolo"), ("de", "Tedesco"),
        ("pt", "Portoghese"), ("ja", "Giapponese"), ("ko", "Coreano"), ("zh", "Cinese"), ("ru", "Russo"), ("ar", "Arabo")
    ]

    var body: some View {
        Form {
            Section(header: Text("Sorgenti"), footer: Text("Come sono scritte le righe dell'elenco delle sorgenti: badge (4K, HDR, audio…), logo dell'addon, formato del testo e badge importati da un link.")) {
                NavigationLink {
                    StreamDisplaySettingsView()
                } label: {
                    Label("Badge, logo e formato delle sorgenti", systemImage: "tag")
                }
                .accessibilityIdentifier("settings.streams")
            }
            Section(header: Text("Motore"),
                    footer: Text("Automatico usa AVPlayer (il player di Apple, l'unico che può mostrare il vero Dolby Vision) per MP4, MOV e HLS, e MPV per MKV, AVI, TS e i file che AVPlayer non sa decodificare. Se un motore non riesce ad aprire il file, Aether prova l'altro una volta.\(RemuxEngineFactory.isAvailable ? " «Converti i file MKV per AVPlayer» fa passare anche gli MKV da AVPlayer: il telefono li rimette al volo in pezzi HLS (video e audio copiati, non ricodificati), così funzionano Picture in Picture e AirPlay. Una traccia audio alla volta, niente sottotitoli incorporati, e non parte se l'audio è solo DTS/TrueHD o il video è VP9/AV1: in quel caso Automatico usa MPV." : "")")) {
                Picker("Player", selection: settings.binding(\.playback.engine)) {
                    ForEach(PlayerEngineChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.engine")
                if RemuxEngineFactory.isAvailable {
                    Toggle("Converti i file MKV per AVPlayer", isOn: settings.binding(\.playback.convertMatroskaForAVPlayer))
                        .accessibilityIdentifier("settings.convertMKV")
                }
                NavigationLink("Stato dei player e dello schermo") { PlayerStatusView() }
            }
            Section(header: Text("Video"),
                    footer: Text(PlaybackEngineFactory.mpvAvailable
                                 ? "Le voci marcate «MPV» agiscono solo quando il video passa dal motore MPV; AVPlayer segue le impostazioni di sistema (HDR automatico). Il buffer vale per entrambi."
                                 : "Il motore MPV non è incluso in questa build: le voci marcate «MPV» non hanno effetto.")) {
                Picker("Uscita HDR (MPV)", selection: settings.binding(\.playback.video.hdrMode)) {
                    ForEach(HDROutputMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Tone mapping (MPV)", selection: settings.binding(\.playback.video.toneMapping)) {
                    ForEach(ToneMappingChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Calcola il picco HDR per fotogramma (MPV)", isOn: settings.binding(\.playback.video.computeHDRPeak))
                Toggle("Decodifica hardware (MPV)", isOn: settings.binding(\.playback.video.hardwareDecoding))
                Toggle("Riduci le bande di colore (MPV)", isOn: settings.binding(\.playback.video.deband))
                NavigationLink("Immagine (MPV)") { PictureControlsView() }
                Picker("Buffer", selection: settings.binding(\.playback.video.bufferSeconds)) {
                    Text("Automatico").tag(0)
                    ForEach([10, 20, 30, 60, 120], id: \.self) { Text("\($0) s").tag($0) }
                }
            }
            Section(header: Text("Ripresa")) {
                Toggle("Riprendi dal punto salvato", isOn: settings.binding(\.playback.autoResume))
                Stepper("Riavvolgi di \(settings.value.playback.resumeRewindSeconds) s alla ripresa", value: settings.binding(\.playback.resumeRewindSeconds), in: 0...30, step: 5)
                VStack(alignment: .leading) {
                    Text("Considera visto oltre il \(Int(settings.value.playback.watchedThreshold * 100))%")
                    Slider(value: settings.binding(\.playback.watchedThreshold), in: 0.5...0.99, step: 0.01)
                }
            }
            Section(header: Text("Controlli")) {
                Picker("Salto indietro", selection: settings.binding(\.playback.skipBackSeconds)) {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Salto avanti", selection: settings.binding(\.playback.skipForwardSeconds)) {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                Stepper("Nascondi i controlli dopo \(settings.value.playback.controlsAutoHideSeconds) s", value: settings.binding(\.playback.controlsAutoHideSeconds), in: 2...10)
                Toggle("Gesti (luminosità, volume, doppio tap)", isOn: settings.binding(\.playback.gesturesEnabled))
                Toggle("Tieni premuto per accelerare", isOn: settings.binding(\.playback.holdToSpeed))
                Picker("Velocità con pressione prolungata", selection: settings.binding(\.playback.holdSpeed)) {
                    ForEach([1.5, 2.0, 3.0, 4.0], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                }
                .disabled(!settings.value.playback.holdToSpeed)
                Toggle("Riproduci sempre in orizzontale", isOn: settings.binding(\.playback.landscapeOnly))
            }
            Section(header: Text("Episodi")) {
                Toggle("Riproduci automaticamente il prossimo episodio", isOn: settings.binding(\.playback.autoplayNextEpisode))
                    .accessibilityIdentifier("settings.autoplay")
                Stepper("Conto alla rovescia: \(settings.value.playback.nextEpisodeCountdownSeconds) s", value: settings.binding(\.playback.nextEpisodeCountdownSeconds), in: 0...30)
                    .disabled(!settings.value.playback.autoplayNextEpisode)
                Toggle("Mostra «Salta intro» e «Salta riassunto»", isOn: settings.binding(\.playback.skipSegmentsEnabled))
                    .accessibilityIdentifier("settings.skipSegments")
                Text("Per sapere dove iniziano e finiscono, Aether chiede a IntroDB (introdb.app) i tempi dell'episodio inviando il codice IMDb del titolo, la stagione e l'episodio. Nessun account, nessun altro dato. I tempi sono inseriti dalla comunità e per una versione diversa del file possono essere sfasati di qualche secondo.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            Section(header: Text("Lingue")) {
                Picker("Audio preferito", selection: settings.binding(\.playback.preferredAudioLanguage)) {
                    Text("Lingua del sistema").tag("system")
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Audio di riserva", selection: settings.binding(\.playback.secondaryAudioLanguage)) {
                    Text("Nessuno").tag("off")
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Sottotitoli", selection: settings.binding(\.playback.preferredSubtitleLanguage)) {
                    Text("Disattivati").tag("off")
                    Text("Lingua del sistema").tag("system")
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Sottotitoli di riserva", selection: settings.binding(\.playback.secondarySubtitleLanguage)) {
                    Text("Nessuno").tag("off")
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Rimuovi le annotazioni per non udenti", isOn: settings.binding(\.playback.stripHearingImpairedTags))
                NavigationLink("Stile dei sottotitoli") { SubtitleStyleView() }
                Stepper(value: settings.binding(\.playback.subtitleDelaySeconds), in: -30...30, step: 0.5) {
                    Text("Ritardo predefinito: \(String(format: "%+.1f", settings.value.playback.subtitleDelaySeconds)) s")
                }
            }
            Section(header: Text("Sorgenti"), footer: Text("«Per addon» mette per prime le sorgenti dell'addon più in alto nella lista degli addon (scheda Addon › Modifica, poi trascina); dentro ogni addon valgono lingua, qualità e codec. «Le migliori per prime» ignora l'addon di provenienza. Vale anche per la scelta automatica.")) {
                Picker("Qualità massima", selection: settings.binding(\.playback.qualityCap)) {
                    ForEach(VideoQualityCap.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Ordine delle sorgenti", selection: settings.binding(\.playback.streamOrdering)) {
                    Text("Per addon").tag(StreamOrdering.byAddon)
                    Text("Le migliori per prime").tag(StreamOrdering.best)
                }
                Toggle("Preferisci sorgenti nella lingua audio", isOn: settings.binding(\.playback.preferStreamsInPreferredAudioLanguage))
                Toggle("Scegli automaticamente la sorgente migliore", isOn: settings.binding(\.playback.autoSelectStream))
            }
            Section(header: Text("Sistema"), footer: Text("L'audio in background richiede la capability «Audio, AirPlay e Picture in Picture» (già attiva). Il video si interrompe se lasci l'app, salvo Picture-in-Picture. Il Picture-in-Picture funziona con i file aperti da AVPlayer (MP4, MOV, HLS, e gli MKV se scegli il player AVPlayer o attivi «Converti i file MKV per AVPlayer»); AVI e gli altri formati passano da MPV, che non lo supporta. Se usi Aether dentro un contenitore come LiveContainer, iOS può non consentirlo.")) {
                Toggle("Picture-in-Picture automatico", isOn: settings.binding(\.playback.autoPictureInPicture))
                Toggle("Continua l'audio in background", isOn: settings.binding(\.playback.allowBackgroundAudio))
                Picker("Timer di spegnimento predefinito", selection: settings.binding(\.playback.defaultSleepTimerMinutes)) {
                    Text("Nessuno").tag(0)
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
            }
        }
        .navigationTitle("Riproduzione")
    }
}

struct PictureControlsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section(footer: Text("Regolazioni del motore MPV (0 = nessuna modifica). Non agiscono su AVPlayer.")) {
                control("Luminosità", \.playback.video.brightness)
                control("Contrasto", \.playback.video.contrast)
                control("Saturazione", \.playback.video.saturation)
                control("Gamma", \.playback.video.gamma)
            }
            Section {
                Button("Azzera") {
                    settings.value.playback.video.brightness = 0
                    settings.value.playback.video.contrast = 0
                    settings.value.playback.video.saturation = 0
                    settings.value.playback.video.gamma = 0
                }
            }
        }
        .navigationTitle("Immagine (MPV)")
    }

    private func control(_ title: String, _ keyPath: WritableKeyPath<AppSettings, Int>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(settings.value[keyPath: keyPath])")
            Slider(value: Binding(get: { Double(settings.value[keyPath: keyPath]) },
                                  set: { settings.value[keyPath: keyPath] = Int($0.rounded()) }),
                   in: -100...100, step: 1)
        }
    }
}

struct SubtitleStyleView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ZStack {
                    LinearGradient(colors: [.indigo, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    SubtitleText(text: "Anteprima dei sottotitoli\nsu due righe", style: settings.value.playback.subtitleStyle, scale: 1)
                        .padding(.bottom, 8)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .listRowInsets(EdgeInsets())
            }
            Section(header: Text("Testo")) {
                VStack(alignment: .leading) {
                    Text("Dimensione: \(Int(settings.value.playback.subtitleStyle.sizePercent))%")
                    Slider(value: settings.binding(\.playback.subtitleStyle.sizePercent), in: 50...200, step: 5)
                }
                Toggle("Grassetto", isOn: settings.binding(\.playback.subtitleStyle.isBold))
                ColorPicker("Colore del testo", selection: colorBinding(\.playback.subtitleStyle.textColor), supportsOpacity: false)
            }
            Section(header: Text("Contorno e sfondo")) {
                Toggle("Contorno", isOn: settings.binding(\.playback.subtitleStyle.outlineEnabled))
                ColorPicker("Colore del contorno", selection: colorBinding(\.playback.subtitleStyle.outlineColor), supportsOpacity: false)
                    .disabled(!settings.value.playback.subtitleStyle.outlineEnabled)
                ColorPicker("Colore dello sfondo", selection: colorBinding(\.playback.subtitleStyle.backgroundColor), supportsOpacity: false)
                VStack(alignment: .leading) {
                    Text("Opacità dello sfondo: \(Int(settings.value.playback.subtitleStyle.backgroundOpacity * 100))%")
                    Slider(value: settings.binding(\.playback.subtitleStyle.backgroundOpacity), in: 0...1, step: 0.05)
                }
            }
            Section(header: Text("Posizione")) {
                VStack(alignment: .leading) {
                    Text("Distanza dal bordo inferiore: \(Int(settings.value.playback.subtitleStyle.bottomOffsetPercent))%")
                    Slider(value: settings.binding(\.playback.subtitleStyle.bottomOffsetPercent), in: 2...40, step: 1)
                }
            }
            Section {
                Button("Ripristina lo stile predefinito") { settings.value.playback.subtitleStyle = SubtitleStyle() }
            }
        }
        .navigationTitle("Stile dei sottotitoli")
    }

    private func colorBinding(_ keyPath: WritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings.value[keyPath: keyPath]) },
                set: { settings.value[keyPath: keyPath] = $0.hexString })
    }
}

// MARK: - Content

struct ContentSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var confirmClearHistory = false
    @State private var confirmClearSearch = false

    var body: some View {
        Form {
            Section(header: Text("Cataloghi e Scopri"), footer: Text("Nome, ordine e visibilità dei cataloghi di ogni addon (valgono in Home, Scopri e Cerca) e le categorie di Scopri.")) {
                NavigationLink {
                    CatalogLayoutSettingsView()
                } label: {
                    Label("Cataloghi: nomi, ordine, visibilità", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("settings.catalogs")
                NavigationLink {
                    DiscoverSettingsView()
                } label: {
                    Label("Categorie di Scopri", systemImage: "safari")
                }
                .accessibilityIdentifier("settings.discover")
            }
            Section(header: Text("Addon")) {
                NavigationLink {
                    AddonsView()
                } label: {
                    LabeledContent("Gestisci gli addon", value: "\(addons.enabledAddons.count)/\(addons.addons.count)")
                }
                Toggle("Nascondi i cataloghi per adulti", isOn: settings.binding(\.content.hideAdultCatalogs))
                Toggle("Nascondi i talk show", isOn: settings.binding(\.content.hideTalkShows))
                if settings.value.content.hideTalkShows {
                    Toggle("Nella Home", isOn: settings.binding(\.content.talkHome))
                    Toggle("In Scopri", isOn: settings.binding(\.content.talkDiscover))
                    Toggle("Nella ricerca", isOn: settings.binding(\.content.talkSearch))
                    Toggle("Nelle filmografie degli attori", isOn: settings.binding(\.content.talkCast))
                    Toggle("Nei titoli simili", isOn: settings.binding(\.content.talkSimilar))
                }
            }
            Section(header: Text("Aggiornamento"), footer: Text("Per quanto tempo un catalogo resta valido prima di essere riscaricato (a meno che l'addon non indichi un valore proprio). Tira verso il basso per forzare l'aggiornamento.")) {
                Picker("Aggiorna i cataloghi ogni", selection: settings.binding(\.content.catalogRefreshMinutes)) {
                    ForEach([1, 5, 10, 30, 60, 360, 1440], id: \.self) { minutes in
                        Text(minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min").tag(minutes)
                    }
                }
            }
            Section(header: Text("Ricerca")) {
                Toggle("Cerca negli addon", isOn: settings.binding(\.content.searchRemote))
                Toggle("Cerca anche nella libreria", isOn: settings.binding(\.content.searchLocal))
                Toggle("Salva le ricerche recenti", isOn: settings.binding(\.content.saveSearchHistory))
                Picker("Ordinamento predefinito", selection: settings.binding(\.content.searchSort)) {
                    ForEach(SearchSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(header: Text("Lingua di trama e dettagli"), footer: Text("Con la chiave TMDB, trama, generi, cast e titoli arrivano in questa lingua anche quando l'addon li fornisce in inglese.")) {
                Picker("Lingua preferita", selection: settings.binding(\.content.preferredLanguage)) {
                    Text("Lingua del sistema").tag("system")
                    Text("Italiano").tag("it")
                    Text("Inglese").tag("en")
                    Text("Francese").tag("fr")
                    Text("Spagnolo").tag("es")
                    Text("Tedesco").tag("de")
                    Text("Portoghese").tag("pt")
                }
                .accessibilityIdentifier("settings.contentLanguage")
            }
            Section(header: Text("Cronologia")) {
                Button("Cancella cronologia di visione", role: .destructive) { confirmClearHistory = true }
                Button("Cancella ricerche recenti", role: .destructive) { confirmClearSearch = true }
            }
        }
        .navigationTitle("Contenuti e scoperta")
        .confirmationDialog("Cancellare la cronologia di visione?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Cancella", role: .destructive) { Task { await env.libraryStore.clearHistory() } }
        }
        .confirmationDialog("Cancellare le ricerche recenti?", isPresented: $confirmClearSearch, titleVisibility: .visible) {
            Button("Cancella", role: .destructive) { Task { await env.libraryStore.clearSearchHistory() } }
        }
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    @State private var report: AppEnvironment.StorageReport?
    @State private var message: String?

    var body: some View {
        Form {
            Section(header: Text("Spazio utilizzato")) {
                LabeledContent("Immagini", value: Format.bytes(report?.images ?? 0))
                LabeledContent("Metadati e cataloghi", value: Format.bytes(report?.metadata ?? 0))
                LabeledContent("Download", value: Format.bytes(report?.downloads ?? 0))
                LabeledContent("Spazio libero", value: Format.bytes(AppPaths.availableCapacity()))
            }
            Section(header: Text("Cache")) {
                Picker("Limite cache immagini", selection: settings.binding(\.storage.imageCacheLimitMB)) {
                    ForEach([100, 300, 600, 1000, 2000], id: \.self) { Text("\($0) MB").tag($0) }
                }
                Toggle("Salva in cache metadati e cataloghi", isOn: settings.binding(\.storage.cacheMetadata))
                Button("Svuota cache immagini") { Task { await env.clearImageCache(); await refresh(); message = "Cache immagini svuotata." } }
                Button("Svuota cache di cataloghi e metadati") { Task { await env.clearMetadataCache(); await refresh(); message = "Cache dei metadati svuotata." } }
                if let message = message { Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary) }
            }
            Section(header: Text("Download")) {
                Toggle("Scarica anche con dati mobili", isOn: settings.binding(\.storage.downloadOverCellular))
                Stepper("Download simultanei: \(settings.value.storage.maxConcurrentDownloads)", value: settings.binding(\.storage.maxConcurrentDownloads), in: 1...4)
                Toggle("Elimina i download dopo la visione", isOn: settings.binding(\.storage.deleteDownloadsAfterWatching))
                NavigationLink("Gestisci i download") { DownloadsView().navigationTitle("Download") }
            }
            Section(header: Text("Diagnostica downloader"),
                    footer: Text("Il log resta sul dispositivo. Gli URL e le credenziali vengono oscurati prima di essere registrati. Attiva la registrazione prima di riprodurre l'errore, poi esporta il file e allegalo alla segnalazione.")) {
                Toggle("Abilita log del downloader", isOn: settings.binding(\.privacy.keepDiagnosticLog))
                    .accessibilityIdentifier("storage.downloaderLogs")
                Toggle("Log dettagliati", isOn: settings.binding(\.advanced.verboseLogging))
                    .disabled(!settings.value.privacy.keepDiagnosticLog)
                NavigationLink("Visualizza e salva log") {
                    DownloadLogView(diagnostics: env.diagnostics)
                }
                .accessibilityIdentifier("storage.viewDownloaderLogs")
            }
            Section(header: Text("Scarica una stagione"), footer: Text("Aether cerca sorgenti per ogni episodio e prova a mantenere la stessa lingua e una qualità coerente. Se non trova una sorgente compatibile, salta solo quell'episodio e lo segnala. La dimensione è stimata: gli addon non sempre comunicano i GB reali.")) {
                Picker("Qualità", selection: settings.binding(\.storage.seasonDownloadQuality)) {
                    ForEach(VideoQualityCap.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Lingua audio", selection: settings.binding(\.storage.seasonDownloadLanguage)) {
                    Text("Come lingua preferita di Riproduzione").tag("preferred")
                    Text("Italiano").tag("it")
                    Text("Inglese").tag("en")
                    Text("Francese").tag("fr")
                    Text("Spagnolo").tag("es")
                    Text("Tedesco").tag("de")
                    Text("Portoghese").tag("pt")
                    Text("Qualsiasi lingua").tag("any")
                }
                Picker("Gestione dello spazio", selection: settings.binding(\.storage.seasonDownloadSizePolicy)) {
                    ForEach(SeasonDownloadSizePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NavigationLink {
                    SeasonDownloadAddonsSettingsView()
                } label: {
                    Label("Addon per i download stagionali", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("settings.seasonDownloadAddons")
            }
        }
        .navigationTitle("Archiviazione")
        .task { await refresh() }
    }

    private func refresh() async {
        report = await env.storageReport()
    }
}

// MARK: - Seasonal download addon preferences

struct SeasonDownloadAddonsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var addons: [AddonHandle] = []

    var body: some View {
        Form {
            Section(footer: Text("Disattivare un addon lo esclude soltanto dalla ricerca dei download stagionali; non cambia la riproduzione normale. I torrent richiedono un provider debrid configurato, ad esempio TorBox.")) {
                if addons.isEmpty {
                    Text("Nessun addon disponibile.")
                        .foregroundStyle(Color.aetherSecondary)
                } else {
                    ForEach(addons, id: \.id) { handle in
                        Toggle(isOn: Binding(
                            get: { !settings.value.storage.seasonDownloadDisabledAddonIDs.contains(handle.id.uuidString) },
                            set: { enabled in
                                var disabled = settings.value.storage.seasonDownloadDisabledAddonIDs
                                if enabled {
                                    disabled.removeAll { $0 == handle.id.uuidString }
                                } else if !disabled.contains(handle.id.uuidString) {
                                    disabled.append(handle.id.uuidString)
                                }
                                settings.value.storage.seasonDownloadDisabledAddonIDs = disabled.sorted()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(handle.addon.displayName)
                                Text("Usa questo addon per i download stagionali")
                                    .font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Addon download stagionali")
        .task { addons = await env.addons.handles() }
    }
}

// MARK: - Casting settings

struct CastingSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var relay: RelayService
    @EnvironmentObject private var network: NetworkMonitor
    @State private var newHost = ""

    /// Where the relay stands, for the row below. Reads the phone's address each time the page is drawn.
    private var relayStatus: String {
        switch relay.availability {
        case .ready(let interface): return "Pronto (\(interface.address))"
        case .unavailable(let reason): return "Non disponibile: \(reason.message)"
        }
    }

    var body: some View {
        Form {
            Section(header: Text("Protocolli")) {
                Toggle("AirPlay", isOn: settings.binding(\.casting.airPlayEnabled))
                Toggle("Google Cast (Chromecast, Android TV con Cast)", isOn: settings.binding(\.casting.googleCastEnabled))
                Toggle("DLNA / UPnP", isOn: settings.binding(\.casting.dlnaEnabled))
            }
            Section(header: Text("DLNA"), footer: Text("La scoperta automatica (SSDP) usa il multicast UDP e richiede l'entitlement «com.apple.developer.networking.multicast» concesso da Apple: senza, non trova nulla. L'aggiunta manuale funziona sempre.")) {
                Toggle("Scoperta automatica SSDP", isOn: settings.binding(\.casting.ssdpDiscoveryEnabled))
                    .disabled(!settings.value.casting.dlnaEnabled)
                ForEach(settings.value.casting.manualDLNAHosts, id: \.self) { host in
                    Text(host).font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in settings.value.casting.manualDLNAHosts.remove(atOffsets: offsets) }
                HStack {
                    TextField("192.168.1.50:49152", text: $newHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Aggiungi") {
                        let trimmed = newHost.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !settings.value.casting.manualDLNAHosts.contains(trimmed) {
                            settings.value.casting.manualDLNAHosts.append(trimmed)
                        }
                        newHost = ""
                    }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section(header: Text("Ponte sul telefono"),
                    footer: Text("Il ponte si accende solo mentre trasmetti e si spegne da solo. Tieni Aether aperto: con lo schermo bloccato la trasmissione può interrompersi.")) {
                LabeledContent("Ponte sul telefono") {
                    Text(relayStatus).multilineTextAlignment(.trailing).foregroundStyle(Color.aetherSecondary)
                }
                .accessibilityIdentifier("settings.relayStatus")
                .id(network.reconnectToken)
                if settings.value.advanced.sendDirectLinkToTV {
                    Label("Attivo: il televisore riceve la chiave TorBox.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if RemuxEngineFactory.isAvailable {
                Section(header: Text("File MKV"),
                        footer: Text("Molti Chromecast e televisori con Cast rifiutano gli MKV. Con questa opzione il telefono li rimette al volo in HLS (video e audio copiati, non ricodificati) e li passa dal ponte: serve il Wi-Fi e il permesso «Rete locale», parte dopo qualche secondo e consuma batteria. Passa una sola traccia audio, senza sottotitoli incorporati. Se il file ha solo audio DTS/TrueHD o un video non copiabile, Aether lo invia com'è, come prima.")) {
                    Toggle("Converti gli MKV per Google Cast", isOn: settings.binding(\.casting.convertMatroskaForGoogleCast))
                        .accessibilityIdentifier("settings.castConvertMKV")
                }
            }
            Section(header: Text("Riproduzione remota")) {
                Toggle("Riprendi sul telefono quando mi disconnetto", isOn: settings.binding(\.casting.resumeLocallyOnDisconnect))
                Toggle("Consenti sorgenti nella rete locale", isOn: settings.binding(\.privacy.allowLocalNetwork))
            }
            Section {
                NavigationLink("Dispositivi, sessioni e diagnostica") { CastView() }
            }
        }
        .navigationTitle("Casting")
    }
}

// MARK: - Account & data

struct AccountDataSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var includeURLs = false
    @State private var includeKeys = false
    @State private var exportURL: URL?
    @State private var showingImporter = false
    /// The backup the viewer picked, read and checked, waiting for the choice of how to restore it.
    @State private var pendingRestore: PickedBackup?
    @State private var resultMessage: String?
    @State private var confirmDelete = false
    @State private var confirmReplace = false
    @State private var applySettings = true

    struct PickedBackup {
        var name: String
        var data: Data
        var preview: BackupPreview
    }

    var body: some View {
        Form {
            Section(header: Text("Account e sincronizzazione")) {
                Label("Nessun account", systemImage: "person.crop.circle.badge.xmark")
                Text("Aether non usa account cloud e non sincronizza tra dispositivi: le API di Stremio e Nuvio non sono pubbliche per client di terze parti. Per spostare i dati usa il backup qui sotto.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            Section(header: Text("Privacy")) {
                Toggle("Registra cronologia e punti di ripresa", isOn: settings.binding(\.privacy.recordHistory))
                    .accessibilityIdentifier("settings.recordHistory")
                Toggle("Consenti rete locale (addon, sorgenti, Cast)", isOn: settings.binding(\.privacy.allowLocalNetwork))
                    .accessibilityIdentifier("settings.allowLocal")
                Toggle("Conserva il log diagnostico (solo su questo dispositivo)", isOn: settings.binding(\.privacy.keepDiagnosticLog))
                Text("Aether non invia nessun dato a server propri: niente analytics, niente crash reporting. Le richieste partono verso gli addon che installi, verso gli indirizzi delle immagini e dei video che questi restituiscono, verso IntroDB per i tempi di «Salta intro» (codice IMDb, stagione ed episodio; si spegne in Riproduzione ▸ Episodi) e, solo se inserisci una tua chiave in Servizi, verso TorBox, TMDB e TheTVDB. Per cercare i sottotitoli gli addon di sottotitoli ricevono il nome del file e, quando è calcolabile, l'impronta (hash) del video.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            Section(header: Text("Backup e ripristino"), footer: Text("Il backup contiene libreria, cronologia, impostazioni e l'elenco degli addon. Gli indirizzi degli addon e le chiavi dei servizi (TorBox, TMDB, TheTVDB, fanart.tv) sono personali: inclusi solo se lo scegli, e il file non è cifrato. Ripristinando un backup con le chiavi, i servizi si configurano da soli.")) {
                Toggle("Includi gli indirizzi degli addon", isOn: $includeURLs)
                Toggle("Includi le chiavi dei servizi", isOn: $includeKeys)
                    .accessibilityIdentifier("backup.includeKeys")
                Button("Crea backup…") { Task { await export() } }
                    .accessibilityIdentifier("backup.export")
                if let url = exportURL {
                    ShareLink(item: url) { Label("Condividi \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
                Button("Ripristina da file…") {
                    resultMessage = nil
                    pendingRestore = nil
                    showingImporter = true
                }
                .accessibilityIdentifier("backup.import")
            }
            if let picked = pendingRestore {
                // Shown in the page itself, not in a dialog: a dialog asked for while the file picker is still closing is dropped by iOS.
                Section(header: Text("Backup scelto"), footer: Text("«Unisci» tiene la versione più recente di ogni elemento. «Sostituisci» cancella prima libreria, cronologia e addon attuali.")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(picked.name).font(.subheadline.weight(.semibold))
                        Text(picked.preview.summary).font(.footnote).foregroundStyle(Color.aetherSecondary)
                        Text("Creato il \(picked.preview.createdAt.formatted(date: .abbreviated, time: .shortened)) con Aether \(picked.preview.appVersion)")
                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("backup.picked")
                    if picked.preview.hasSettings {
                        Toggle("Ripristina anche le impostazioni", isOn: $applySettings)
                            .accessibilityIdentifier("backup.applySettings")
                    }
                    Button("Unisci ai dati attuali") { Task { await restore(.merge) } }
                        .accessibilityIdentifier("backup.merge")
                    Button("Sostituisci tutto…", role: .destructive) { confirmReplace = true }
                        .accessibilityIdentifier("backup.replace")
                        .confirmationDialog("Sostituire i dati attuali?", isPresented: $confirmReplace, titleVisibility: .visible) {
                            Button("Sostituisci tutto", role: .destructive) { Task { await restore(.replace) } }
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("Libreria, cronologia e addon di questo telefono vengono cancellati e rimpiazzati da quelli del backup.")
                        }
                    Button("Annulla") { pendingRestore = nil }
                        .accessibilityIdentifier("backup.cancel")
                }
            }
            if let message = resultMessage {
                Section { Text(message).font(.footnote).accessibilityIdentifier("backup.message") }
            }
            Section(header: Text("Esporta i miei dati"), footer: Text("Il backup è anche l'esportazione completa dei tuoi dati in JSON leggibile.")) {
                EmptyView()
            }
            Section {
                Button("Elimina tutti i dati locali…", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("data.delete")
                    // One dialog per button: several on the same view make iOS drop all but one.
                    .confirmationDialog("Eliminare tutti i dati locali?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Elimina tutto", role: .destructive) { Task { await env.deleteAllLocalData(); resultMessage = "Dati locali eliminati." } }
                    } message: {
                        Text("L'operazione non si può annullare.")
                    }
            } footer: {
                Text("Rimuove libreria, cronologia, addon (anche dal Portachiavi), download, cache e impostazioni.")
            }
        }
        .navigationTitle("Account e dati")
        // Any file can be picked: a backup saved or renamed by another app may not be typed as JSON, and the check is the content.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .plainText, .data, .item]) { result in
            switch result {
            case .success(let url):
                loadBackup(from: url)
            case .failure(let error):
                resultMessage = "Non riesco ad aprire il file: \(error.localizedDescription)"
            }
        }
    }

    private func export() async {
        do {
            exportURL = try await BackupService.makeBackup(env: env, includeAddonURLs: includeURLs, includeServiceKeys: includeKeys)
            resultMessage = (includeURLs || includeKeys) ? "Backup creato con dati personali (indirizzi degli addon o chiavi): conservalo con cura." : "Backup creato."
        } catch {
            resultMessage = "Backup non riuscito: \(error.localizedDescription)"
        }
    }

    /// Reads and checks the picked file now, so a file that is not a backup is said so at once and a good one shows what it holds.
    private func loadBackup(from url: URL) {
        do {
            let data = try BackupFileReader.read(url)
            let backup = try BackupCodec.decode(data)
            pendingRestore = PickedBackup(name: url.lastPathComponent, data: data, preview: BackupPreview(backup))
            resultMessage = nil
        } catch let error as BackupError {
            pendingRestore = nil
            resultMessage = "«\(url.lastPathComponent)»: \(error.message)"
        } catch let error as BackupFileError {
            pendingRestore = nil
            resultMessage = error.message
        } catch {
            pendingRestore = nil
            resultMessage = "Non riesco ad aprire il file: \(error.localizedDescription)"
        }
    }

    private func restore(_ mode: RestoreMode) async {
        guard let picked = pendingRestore else { return }
        pendingRestore = nil
        do {
            let summary = try await BackupService.restore(data: picked.data, env: env, mode: mode, applySettings: applySettings)
            resultMessage = "Ripristino completato: \(summary.entries) titoli salvati, \(summary.progressRecords) punti di visione, \(summary.addonsAdded) addon\(summary.addonsWithoutURL > 0 ? " (\(summary.addonsWithoutURL) senza indirizzo: da reinstallare)" : "")." + (summary.keysRestored.isEmpty ? "" : " Chiavi configurate: \(summary.keysRestored.joined(separator: ", ")).")
        } catch let error as BackupError {
            resultMessage = error.message
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}


private struct DownloadLogView: View {
    let diagnostics: DiagnosticLog
    @State private var entries: [LogEntry] = []
    @State private var exportURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("\(entries.count) eventi registrati")
                        .foregroundStyle(Color.aetherSecondary)
                    Spacer()
                    Button("Aggiorna") { Task { await refresh() } }
                }
                Button("Svuota log", role: .destructive) {
                    Task {
                        await diagnostics.clear()
                        await refresh()
                        exportURL = nil
                        statusMessage = "Log svuotato."
                    }
                }
                Button("Esporta log…") { Task { await export() } }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Condividi file di log", systemImage: "square.and.arrow.up")
                    }
                }
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
            }
            Section("Eventi") {
                if entries.isEmpty {
                    Text("Nessun evento registrato. Abilita i log in Archiviazione e riprova il download.")
                        .foregroundStyle(Color.aetherSecondary)
                } else {
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.label).font(.caption.monospaced().weight(.bold))
                                Text(entry.category).font(.caption.monospaced())
                                Spacer()
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(Color.aetherSecondary)
                            }
                            Text(entry.message).font(.footnote).textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Log downloader")
        .task { await refresh() }
    }

    private func refresh() async {
        entries = await diagnostics.entries()
    }

    private func export() async {
        let text = await diagnostics.exportText(header: ["Aether downloader diagnostics"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aether-downloader-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            statusMessage = "Log pronto da condividere."
        } catch {
            statusMessage = "Impossibile esportare il log: \(error.localizedDescription)"
        }
    }
}
