import SwiftUI
import AetherCore

/// Settings > Aspetto > Stile e grafica: the atmosphere (palette), the background, and the shape of posters and cards, with a
/// live preview at the top.
struct StyleSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var appearance: AppearanceSettings { settings.value.appearance }

    var body: some View {
        Form {
            Section(header: Text("Anteprima")) {
                StylePreview()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section(header: Text("Atmosfera"),
                    footer: Text("I colori dello sfondo. Non toccano il testo: la leggibilità è la stessa con ogni atmosfera.")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                    ForEach(AppPalette.allCases.filter { appearance.isAvailable($0) }, id: \.self) { palette in
                        paletteChip(palette)
                    }
                }
                .padding(.vertical, 6)
            }
            Section(header: Text("Sfondo"), footer: Text(backdropFooter)) {
                Picker("Sfondo", selection: settings.binding(\.appearance.backdrop)) {
                    ForEach(BackdropStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.style.backdrop")
            }
            Section(header: Text("Schede e testi")) {
                Picker("Cornice", selection: settings.binding(\.appearance.cardChrome)) {
                    ForEach(CardChrome.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.style.chrome")
                Picker("Angoli", selection: settings.binding(\.appearance.cornerStyle)) {
                    ForEach(CornerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.style.corners")
                Picker("Carattere dei titoli", selection: settings.binding(\.appearance.titleFont)) {
                    ForEach(TitleFont.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.style.font")
            }
            Section {
                Button("Ripristina lo stile di Aether") {
                    var a = settings.value.appearance
                    a.palette = .aether
                    a.backdrop = .aurora
                    a.cardChrome = .standard
                    a.cornerStyle = .standard
                    a.titleFont = .rounded
                    settings.value.appearance = a
                }
                .accessibilityIdentifier("settings.style.reset")
            }
        }
        .navigationTitle("Stile e grafica")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backdropFooter: String {
        var text = "Aurora e Faro sono fermi; Onde si muove piano. Con «Animazioni» spente, «Riduci movimento» o il Risparmio energetico lo sfondo resta fermo, e con «Riduci gli effetti visivi» diventa uniforme."
        if appearance.backdrop == .flow && !settings.animationsEnabled {
            text += " Le animazioni sono spente: Onde resta fermo."
        }
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
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(palette.emoji).font(.system(size: 20))
                }
                .frame(width: 46, height: 46)
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 3 : 0).padding(-4))
                Text(palette.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(Color.aetherSecondary)
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
