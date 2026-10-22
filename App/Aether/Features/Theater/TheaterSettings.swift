import SwiftUI

/// The viewer's choices for Theater Mode, kept in the app's own preferences (they matter only here).
enum TheaterPrefs {
    static let size = "theater.cardSize"
    static let portrait = "theater.portraitCards"
    static let intro = "theater.intro"
    static let sprockets = "theater.sprockets"
    static let titles = "theater.titles"
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.45)
}

struct TheaterSettingsView: View {
    @AppStorage(TheaterPrefs.size) private var size = 1
    @AppStorage(TheaterPrefs.portrait) private var portrait = false
    @AppStorage(TheaterPrefs.intro) private var intro = true
    @AppStorage(TheaterPrefs.sprockets) private var sprockets = true
    @AppStorage(TheaterPrefs.titles) private var titles = true

    var body: some View {
        Form {
            Section(header: Text("Locandine")) {
                Picker("Dimensione", selection: $size) {
                    Text("Piccole").tag(0)
                    Text("Medie").tag(1)
                    Text("Grandi").tag(2)
                }
                .pickerStyle(.segmented)
                Toggle("Locandine verticali", isOn: $portrait)
                Toggle("Titolo sotto ogni locandina", isOn: $titles)
            }
            Section(header: Text("Atmosfera")) {
                Toggle("Introduzione cinematografica", isOn: $intro)
                Toggle("Fori della pellicola sulle righe", isOn: $sprockets)
            }
        }
        .navigationTitle("Theater Mode")
        .accessibilityIdentifier("theater.settings")
    }
}
