import SwiftUI
import UIKit
import AetherCore

/// Settings ▸ Aspetto. One page, top to bottom: a live preview, ready-made looks, then colours, background, cards, Home, motion and the
/// cinema extras. Every row changes the app at once; the preview at the top shows what a card looks like with the choices made.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var appearance: AppearanceSettings { settings.value.appearance }

    var body: some View {
        Form {
            Section {
                StylePreview()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            presets
            colours
            background
            cards
            home
            motion
            cinema
            shortcuts
            Section {
                NavigationLink { AppIconSettingsView() } label: { Label("Icona dell'app", systemImage: "app.badge.fill") }
            }
            Section(footer: Text("Torna all'aspetto standard di Aether. Il nome del saluto, l'ordine della Home e le dimensioni restano come sono.")) {
                Button("Ripristina l'aspetto di Aether", role: .destructive) {
                    var a = settings.value.appearance
                    a.resetLook()
                    settings.value.appearance = a
                    Haptics.success()
                }
                .accessibilityIdentifier("settings.style.reset")
            }
        }
        .navigationTitle("Aspetto")
        .navigationBarTitleDisplayMode(.inline)
        .animation(settings.animationsEnabled ? .easeInOut(duration: 0.2) : nil, value: appearance)
    }

    // MARK: Looks

    private var presets: some View {
        Section(header: Text("Stili pronti"), footer: Text("Un tocco cambia colori, sfondo, schede, angoli e carattere insieme. Poi puoi ritoccare ogni voce qui sotto.")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(LookPreset.allCases, id: \.self) { preset in presetCard(preset) }
                }
                .padding(.vertical, 6)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    private func presetCard(_ preset: LookPreset) -> some View {
        var sample = AppearanceSettings()
        preset.apply(to: &sample)
        let accent = sample.customAccentHex.map { Color(hex: $0) } ?? Theme.accent(for: sample.accent)
        let background: Color = sample.amoled ? .black : (sample.theme == .system ? Color(UIColor.systemGray5) : Color(red: 0.03, green: 0.04, blue: 0.1))
        return Button {
            var a = settings.value.appearance
            preset.apply(to: &a)
            settings.value.appearance = a
            Haptics.select()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    background
                    RadialGradient(colors: [accent.opacity(sample.backdrop == .plain ? 0 : 0.55), .clear], center: .topTrailing, startRadius: 4, endRadius: 90)
                    RoundedRectangle(cornerRadius: CGFloat(sample.cornerStyle.radius) / 2.4, style: .continuous)
                        .fill(accent.opacity(0.85))
                        .frame(width: 34, height: 50)
                        .shadow(color: sample.cardChrome == .glow ? accent.opacity(0.8) : .clear, radius: 8)
                        .overlay(RoundedRectangle(cornerRadius: CGFloat(sample.cornerStyle.radius) / 2.4, style: .continuous)
                            .stroke(sample.cardChrome == .outline ? Color.white.opacity(0.8) : .clear, lineWidth: 1.5))
                }
                .frame(width: 104, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(preset.title).font(.system(.subheadline, design: .rounded).weight(.bold))
                Text(preset.summary).font(.caption2).foregroundStyle(Color.aetherSecondary).lineLimit(2).frame(width: 104, alignment: .leading)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(preset.title)
        .accessibilityHint(preset.summary)
    }

    // MARK: Colours

    private var colours: some View {
        Section(header: Text("Colori"), footer: Text("Il tema e l'accento valgono per tutta l'app. L'atmosfera tinge solo lo sfondo, mai il testo.")) {
            Picker("Tema", selection: settings.binding(\.appearance.theme)) {
                ForEach(ThemeMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.theme")
            VStack(alignment: .leading, spacing: 10) {
                Text("Accento")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                    ForEach(AccentChoice.allCases, id: \.self) { choice in
                        let selected = appearance.customAccentHex == nil && appearance.accent == choice
                        Button {
                            settings.value.appearance.customAccentHex = nil
                            settings.value.appearance.accent = choice
                            Haptics.select()
                        } label: {
                            Circle().fill(Theme.accent(for: choice).gradient)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 3 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 4)
            Toggle("Accento personalizzato", isOn: Binding(get: { appearance.customAccentHex != nil }, set: { enabled in
                settings.value.appearance.customAccentHex = enabled ? (appearance.customAccentHex ?? "#6E78FF") : nil
            }))
            if appearance.customAccentHex != nil {
                ColorPicker("Colore", selection: hexBinding(\.customAccentHex, fallback: "#6E78FF"), supportsOpacity: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Atmosfera")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                    ForEach(AppPalette.allCases.filter { appearance.isAvailable($0) }, id: \.self) { palette in paletteChip(palette) }
                }
            }
            .padding(.vertical, 4)
            Toggle("Neri totali (AMOLED)", isOn: settings.binding(\.appearance.amoled))
                .accessibilityIdentifier("settings.style.amoled")
        }
    }

    // MARK: Background

    private var background: some View {
        Section(header: Text("Sfondo"), footer: Text(backdropFooter)) {
            Picker("Stile", selection: settings.binding(\.appearance.backdrop)) {
                ForEach(BackdropStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.style.backdrop")
            if appearance.backdrop != .plain {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Intensità")
                    Slider(value: settings.binding(\.appearance.backdropIntensity), in: 0...1)
                        .accessibilityLabel("Intensità dello sfondo")
                }
            }
            Toggle("Colore di sfondo personalizzato", isOn: Binding(get: { appearance.customBackgroundHex != nil }, set: { enabled in
                settings.value.appearance.customBackgroundHex = enabled ? (appearance.customBackgroundHex ?? "#0A0F1F") : nil
            }))
            if appearance.customBackgroundHex != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(AppearanceSettingsView.backgroundPresets, id: \.hex) { preset in
                            Button { settings.value.appearance.customBackgroundHex = preset.hex } label: {
                                Circle().fill(Color(hex: preset.hex))
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: appearance.customBackgroundHex == preset.hex ? 3 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ColorPicker("Altro colore", selection: hexBinding(\.customBackgroundHex, fallback: "#0A0F1F"), supportsOpacity: false)
            }
        }
    }

    // MARK: Cards

    private var cards: some View {
        Section(header: Text("Locandine e schede")) {
            Picker("Cornice", selection: settings.binding(\.appearance.cardChrome)) {
                ForEach(CardChrome.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.style.chrome")
            Picker("Angoli", selection: settings.binding(\.appearance.cornerStyle)) {
                ForEach(CornerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.style.corners")
            Picker("Dimensione", selection: settings.binding(\.appearance.posterSize)) {
                ForEach(PosterSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Densità", selection: settings.binding(\.appearance.density)) {
                ForEach(CatalogDensity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Carattere dei titoli", selection: settings.binding(\.appearance.titleFont)) {
                ForEach(TitleFont.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.style.font")
            Toggle("Voto sulle locandine", isOn: settings.binding(\.appearance.showPosterRatings))
        }
    }

    // MARK: Home

    private var home: some View {
        Section(header: Text("Home"), footer: Text("Sezioni e ordine, il carosello in evidenza e il saluto. Nomi e ordine dei cataloghi sono in Impostazioni ▸ Cataloghi e scoperta.")) {
            NavigationLink { HomeLayoutSettingsView() } label: { Label("Personalizza la Home", systemImage: "rectangle.3.group") }
                .accessibilityIdentifier("settings.homeLayout")
        }
    }

    // MARK: Motion

    private var motion: some View {
        Section(header: Text("Movimento"), footer: Text("Con «Riduci gli effetti» lo sfondo diventa uniforme e il vetro opaco. Aether rispetta anche «Riduci movimento» e «Riduci trasparenza» di iOS. Lo zoom dalla locandina funziona solo con il titolo a schermo intero: con lo zoom acceso la scheda si apre a schermo intero (con la X per chiudere); spegnilo per avere la scheda che si chiude scorrendo in basso.")) {
            Toggle("Animazioni", isOn: settings.binding(\.appearance.animationsEnabled))
            Toggle("Feedback tattile", isOn: settings.binding(\.appearance.haptics))
            Picker("Apri i titoli come", selection: settings.binding(\.appearance.detailAsCard)) {
                Text("Scheda (scorri in basso per chiudere)").tag(true)
                Text("Schermo intero").tag(false)
            }
            Toggle("Il titolo cresce dalla locandina (iOS 18+, a schermo intero)", isOn: settings.binding(\.appearance.zoomTransition))
            Toggle("Pagina del film cinematografica", isOn: settings.binding(\.appearance.dynamicCinematic))
                .accessibilityIdentifier("settings.style.cinematic")
            if appearance.dynamicCinematic {
                Toggle("Colori dell'artwork sullo sfondo", isOn: settings.binding(\.appearance.moodColors))
                Toggle("Zoom lento e dissolvenza all'apertura", isOn: settings.binding(\.appearance.cinematicMotion))
            }
            Toggle("Immagini che sfumano all'arrivo", isOn: settings.binding(\.appearance.imageFades))
            Toggle("Zoom lento nella Scoperta, nell'ambiente e nei titoli di coda", isOn: settings.binding(\.appearance.kenBurns))
            Toggle("Riduci gli effetti", isOn: settings.binding(\.appearance.reduceVisualEffects))
                .accessibilityIdentifier("settings.reduceEffects")
        }
    }

    // MARK: Cinema

    private var cinema: some View {
        Section(header: Text("Cinema"), footer: Text("L'apertura è una breve animazione con un suono originale prima del film; i titoli di coda diventano una schermata con il cast, una citazione e cosa vedere dopo.")) {
            Toggle("Apertura cinematografica prima del film", isOn: settings.binding(\.appearance.cinematicOpening))
            if appearance.cinematicOpening {
                Toggle("Suono dell'apertura", isOn: settings.binding(\.appearance.openingSound))
            }
            Toggle("Titoli di coda in scena", isOn: settings.binding(\.appearance.creditsExperience))
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Section(header: Text("Scorciatoie"), footer: Text("Nascondi quello che non usi: le funzioni restano, spariscono solo i punti d'ingresso.")) {
            Toggle("Scoperta, Calendario e Per te in Scopri", isOn: settings.binding(\.appearance.showExplore))
            Toggle("«Il mio universo» nel Profilo", isOn: settings.binding(\.appearance.showCinemaCard))
        }
    }

    // MARK: Helpers

    static let backgroundPresets: [(name: String, hex: String)] = [
        ("Nero", "#000000"), ("Notte", "#0A0F1F"), ("Grafite", "#1C1C1E"), ("Viola scuro", "#160B26"),
        ("Verde bosco", "#07160F"), ("Bordeaux", "#1F0A12"), ("Blu oceano", "#04162B"), ("Marrone caffè", "#1A1008"),
        ("Bianco", "#FFFFFF"), ("Grigio chiaro", "#F2F2F7")
    ]

    private func hexBinding(_ path: WritableKeyPath<AppearanceSettings, String?>, fallback: String) -> Binding<Color> {
        Binding(get: { Color(hex: settings.value.appearance[keyPath: path] ?? fallback) }, set: { color in
            let ui = UIColor(color)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
            guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            settings.value.appearance[keyPath: path] = String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        })
    }

    private var backdropFooter: String {
        var text = "Aurora e Faro sono fermi; Onde si muove piano. Con le animazioni spente, «Riduci movimento» o il Risparmio energetico lo sfondo resta fermo."
        if appearance.backdrop == .flow && !settings.animationsEnabled { text += " Le animazioni sono spente: Onde resta fermo." }
        return text
    }

    private func paletteChip(_ palette: AppPalette) -> some View {
        let selected = appearance.palette == palette
        let colors: [Color]
        if let washes = palette.washes {
            colors = [Color(hex: washes.primary), Color(hex: washes.secondary)]
        } else {
            colors = [settings.accentColor, .cyan]
        }
        return Button {
            settings.value.appearance.palette = palette
            Haptics.select()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(palette.emoji).font(.system(size: 20))
                }
                .frame(width: 46, height: 46)
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 3 : 0).padding(-4))
                Text(palette.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(Color.aetherSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(palette.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("settings.palette.\(palette.rawValue)")
    }
}

/// A poster, a wide card and a title drawn with the current choices, over the current background.
private struct StylePreview: View {
    @Environment(\.aetherStyle) private var style
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            AetherBackdrop()
            HStack(alignment: .top, spacing: 14) {
                card(width: 84, height: 126, radius: style.posterRadius, seed: "Locandina", label: "Locandina")
                card(width: 150, height: 84, radius: style.landscapeRadius, seed: "Orizzontale", label: "Orizzontale")
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Anteprima dello stile scelto")
        .accessibilityIdentifier("settings.style.preview")
    }

    private func card(width: CGFloat, height: CGFloat, radius: CGFloat, seed: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Theme.fallbackGradient(for: seed)
                Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .aetherCardChrome(cornerRadius: radius)
            Text(label)
                .font(.system(.footnote, design: AetherTypography.design).weight(.semibold))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}
