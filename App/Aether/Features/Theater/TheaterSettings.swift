import SwiftUI

/// The viewer's choices for Theater Mode, kept in the app's own preferences (they matter only here).
enum TheaterPrefs {
    static let size = "theater.cardSize"
    static let portrait = "theater.portraitCards"
    static let intro = "theater.intro"
    static let sound = "theater.sound"
    static let sprockets = "theater.sprockets"
    static let titles = "theater.titles"
    static let details = "theater.details"
    static let palette = "theater.palette"
    static let background = "theater.background"
    static let corners = "theater.corners"
    static let border = "theater.border"
    static let glow = "theater.glow"
    static let railLabels = "theater.railLabels"
    static let rowStyle = "theater.rowStyle"
    /// Version of the Theater Mode interface (not of the app).
    static let version = "0.0.1"
}

/// The accent colour of Theater Mode.
enum TheaterPalette: Int, CaseIterable, Identifiable {
    case gold, velvet, midnight, emerald, silver
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .gold: return "Oro"
        case .velvet: return "Rosso velluto"
        case .midnight: return "Blu notte"
        case .emerald: return "Smeraldo"
        case .silver: return "Argento"
        }
    }
    var color: Color {
        switch self {
        case .gold: return Color(red: 1.0, green: 0.82, blue: 0.45)
        case .velvet: return Color(red: 0.93, green: 0.3, blue: 0.34)
        case .midnight: return Color(red: 0.45, green: 0.65, blue: 1.0)
        case .emerald: return Color(red: 0.35, green: 0.86, blue: 0.62)
        case .silver: return Color(red: 0.85, green: 0.88, blue: 0.93)
        }
    }
    static func color(_ raw: Int) -> Color { (TheaterPalette(rawValue: raw) ?? .gold).color }
}

struct TheaterSettingsView: View {
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @AppStorage(TheaterPrefs.background) private var background = 1
    @AppStorage(TheaterPrefs.size) private var size = 1
    @AppStorage(TheaterPrefs.portrait) private var portrait = false
    @AppStorage(TheaterPrefs.corners) private var corners = 1
    @AppStorage(TheaterPrefs.border) private var border = 1
    @AppStorage(TheaterPrefs.glow) private var glow = true
    @AppStorage(TheaterPrefs.titles) private var titles = true
    @AppStorage(TheaterPrefs.details) private var details = true
    @AppStorage(TheaterPrefs.rowStyle) private var rowStyle = 0
    @AppStorage(TheaterPrefs.railLabels) private var railLabels = false
    @AppStorage(TheaterPrefs.intro) private var intro = true
    @AppStorage(TheaterPrefs.sound) private var sound = true
    @AppStorage(TheaterPrefs.sprockets) private var sprockets = false

    var body: some View {
        Form {
            Section(header: Text("Colori")) {
                Picker("Colore d'accento", selection: $palette) {
                    ForEach(TheaterPalette.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Picker("Sfondo", selection: $background) {
                    Text("Nero puro").tag(0)
                    Text("Sfumato").tag(1)
                    Text("Sala (fascio di luce)").tag(2)
                }
            }
            Section(header: Text("Locandine")) {
                Picker("Dimensione", selection: $size) {
                    Text("Piccole").tag(0)
                    Text("Medie").tag(1)
                    Text("Grandi").tag(2)
                }
                .pickerStyle(.segmented)
                Toggle("Locandine verticali", isOn: $portrait)
                Picker("Angoli", selection: $corners) {
                    Text("Netti").tag(0)
                    Text("Morbidi").tag(1)
                    Text("Arrotondati").tag(2)
                }
                Picker("Bordo", selection: $border) {
                    Text("Nessuno").tag(0)
                    Text("Sottile").tag(1)
                    Text("Colore d'accento").tag(2)
                }
                Toggle("Alone sulla locandina premuta", isOn: $glow)
                Toggle("Titolo sotto ogni locandina", isOn: $titles)
                Toggle("Anno e genere", isOn: $details)
            }
            Section(header: Text("Righe e barra")) {
                Picker("Titoli delle righe", selection: $rowStyle) {
                    Text("Normale").tag(0)
                    Text("Con grazie").tag(1)
                    Text("Maiuscoletto").tag(2)
                }
                Toggle("Fori della pellicola sulle righe", isOn: $sprockets)
                Toggle("Nomi accanto alle icone della barra", isOn: $railLabels)
            }
            Section(header: Text("Avvio")) {
                Toggle("Introduzione cinematografica", isOn: $intro)
                Toggle("Suono d'ingresso", isOn: $sound)
            }
            Section {
                LabeledContent("Versione dell'interfaccia", value: TheaterPrefs.version)
            }
        }
        .navigationTitle("Theater Mode")
        .accessibilityIdentifier("theater.settings")
    }
}
