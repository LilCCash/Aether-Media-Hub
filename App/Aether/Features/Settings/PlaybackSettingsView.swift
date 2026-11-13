import SwiftUI
import AetherCore

// MARK: - Playback

struct PlaybackSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private static let languages: [(String, String)] = [
        ("it", "Italiano"), ("en", "Inglese"), ("fr", "Francese"), ("es", "Spagnolo"), ("de", "Tedesco"),
        ("pt", "Portoghese"), ("ja", "Giapponese"), ("ko", "Coreano"), ("zh", "Cinese"), ("ru", "Russo"), ("ar", "Arabo")
    ]

    var body: some View {
        Form {
            Section(header: Text("Modalità Cinema"), footer: Text("Prima del film compare la sua locandina panoramica con il logo, e mentre scorre restano solo l'immagine e la barra: sottotitoli, audio e il resto sono nel menu con i tre puntini. Si accende anche da lì.")) {
                Toggle("Modalità Cinema", isOn: settings.binding(\.playback.cinemaMode))
                    .accessibilityIdentifier("settings.cinema")
            }
            Section(header: Text("Sorgenti"), footer: Text("Come sono scritte le righe dell'elenco delle sorgenti: badge (4K, HDR, audio…), logo dell'addon, formato del testo e badge importati da un link.")) {
                NavigationLink {
                    StreamDisplaySettingsView()
                } label: {
                    Label("Badge, logo e formato delle sorgenti", systemImage: "tag")
                }
                .accessibilityIdentifier("settings.streams")
            }
            Section(header: Text("Motore"),
                    footer: Text("Automatico usa AVPlayer (il player di Apple, l'unico che può mostrare il vero Dolby Vision) per MP4, MOV e HLS, e MPV per MKV, AVI, TS e i file che AVPlayer non sa decodificare. Se un motore non riesce ad aprire il file, Aether prova l'altro una volta. I canali in diretta hanno il loro lettore («Player per le dirette»): con AVPlayer, un formato che non sa aprire (TS…) passa a MPV, a meno che tu non attivi «Conversione delle dirette».\(RemuxEngineFactory.isAvailable ? " «Converti i file per AVPlayer» fa passare anche MKV, AVI e gli altri formati da AVPlayer: il telefono li rimette al volo in pezzi HLS, così funzionano Picture in Picture e AirPlay, con una traccia audio alla volta (la cambi dal pannello Audio) e i sottotitoli di testo del file. Conversione «Leggera»: video e audio copiati, quasi senza consumo, ma non passano video H.264 a 10 bit, VP9, AV1, MPEG-2… né audio solo DTS/TrueHD (in quel caso Automatico usa MPV). «Completa»: quello che il lettore di sistema non legge viene ricodificato sul telefono (video con il codificatore hardware, audio in AAC 5.1/stereo), quindi passa tutto tranne il Dolby Vision profilo 5; consuma più batteria e scalda il telefono, e la decodifica di AV1/VP9 4K può non stare al passo sui modelli più vecchi." : "")")) {
                Picker("Player", selection: settings.binding(\.playback.engine)) {
                    ForEach(PlayerEngineChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.engine")
                Picker("Player per le dirette", selection: settings.binding(\.playback.liveEngine)) {
                    ForEach(PlayerEngineChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.liveEngine")
                NavigationLink("Live TV: playlist e cataloghi") { LiveTVSettingsView() }
                    .accessibilityIdentifier("settings.liveCatalogs")
                if RemuxEngineFactory.isAvailable {
                    Toggle("Converti i file per AVPlayer", isOn: settings.binding(\.playback.convertMatroskaForAVPlayer))
                        .accessibilityIdentifier("settings.convertMKV")
                    Picker("Conversione", selection: settings.binding(\.playback.conversionMode)) {
                        ForEach(ConversionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("settings.conversionMode")
                    NavigationLink {
                        LiveConversionSettingsView()
                    } label: {
                        LabeledContent("Conversione delle dirette", value: settings.value.playback.liveConversion ? "Attiva" : "Spenta")
                    }
                    .accessibilityIdentifier("settings.liveConversion")
                }
                if PlaybackEngineFactory.mpvAvailable {
                    Toggle("Picture in Picture anche con MPV (sperimentale)", isOn: settings.binding(\.playback.mpvPictureInPicture))
                        .accessibilityIdentifier("settings.mpvPiP")
                    Text("MPV disegna il video con il processore invece che con la scheda grafica, così la finestra flottante può mostrarlo: più batteria, immagine ridotta a 1280 punti. I file HDR e Dolby Vision non possono passare di qui (i colori uscirebbero scuri e sbiaditi): appena MPV li riconosce si riaprono da soli sull'uscita normale, che li converte per lo schermo, e per quei file la finestra flottante non c'è. Vale dal prossimo video. Se non funziona, MPV torna da solo all'uscita normale.")
                        .font(.footnote).foregroundStyle(Color.aetherSecondary)
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
                Toggle("Schermata d'avvio dei film (logo e «Guarda»)", isOn: settings.binding(\.playback.introMovies))
                Toggle("Schermata d'avvio degli episodi", isOn: settings.binding(\.playback.introSeries))
                Toggle("Schermata d'avvio dei canali live", isOn: settings.binding(\.playback.introLive))
            }
            Section(header: Text("Cambio episodio"), footer: Text("Quando nel player scegli un altro episodio. «Mostra l'elenco delle fonti» apre la lista delle fonti di quell'episodio; il salto automatico a fine episodio non si ferma mai a chiedere. Con «Usa prima il pack» un episodio che è nello stesso file (una stagione completa) si apre subito, senza cercare. Con «Apri prima gli episodi scaricati» un episodio già nei Download si apre dal file, anche offline; spegnila per scegliere sempre tra le fonti.")) {
                Picker("Cambiando episodio", selection: settings.binding(\.playback.episodeSwitch)) {
                    ForEach(EpisodeSwitchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.episodeSwitch")
                Toggle("Usa prima il pack già aperto", isOn: settings.binding(\.playback.preferPack))
                    .accessibilityIdentifier("settings.preferPack")
                Toggle("Apri prima gli episodi scaricati", isOn: settings.binding(\.playback.preferDownloaded))
                    .accessibilityIdentifier("settings.preferDownloaded")
            }
            Section(header: Text("LiveContainer"), footer: Text("Per aprire un video in un lettore che gira dentro LiveContainer. Scrivi l'id (bundle identifier) dell'app ospite, per esempio org.videolan.vlc-ios; lascia vuoto per nascondere la voce. «Formato» è il modo in cui quel lettore riceve l'indirizzo. Non l'ho provato su un dispositivo: se non parte, controlla id e formato.")) {
                TextField("Id dell'app ospite", text: settings.binding(\.playback.liveContainerBundleID))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings.liveContainerBundle")
                TextField("Schema di LiveContainer", text: settings.binding(\.playback.liveContainerScheme))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Formato", selection: settings.binding(\.playback.liveContainerPlayer)) {
                    ForEach(ExternalPlayer.allCases, id: \.self) { Text($0.title).tag($0) }
                }
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
                Toggle("Cerca anche nel catalogo OpenSubtitles.org", isOn: settings.binding(\.playback.openSubtitlesCatalog))
                    .accessibilityIdentifier("settings.openSubtitlesCatalog")
                Text("L'addon OpenSubtitles v3 ha solo una parte dei sottotitoli del sito: per molti film manca l'italiano. Con questa voce Aether chiede anche al catalogo completo di OpenSubtitles.org, nelle lingue dei sottotitoli scelte qui sopra (o nella lingua del telefono), e li aggiunge alla lista.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
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
        .aetherPage()
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
        .aetherPage()
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
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
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
        .aetherPage()
        .navigationTitle("Stile dei sottotitoli")
    }

    private func colorBinding(_ keyPath: WritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings.value[keyPath: keyPath]) },
                set: { settings.value[keyPath: keyPath] = $0.hexString })
    }
}
