import SwiftUI
import AetherCore

/// Settings ▸ Intelligenza delle fonti: what counts when Aether orders the sources of a title. Everything here only changes the order
/// (a source that cannot be played stays at the bottom whatever the weights say).
struct SourceScoringSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var scoring: Binding<SourceScoring> {
        Binding(get: { settings.value.playback.sourceScoring }, set: { settings.value.playback.sourceScoring = $0 })
    }

    var body: some View {
        Form {
            Section {
                Text("Scegli che peso dare a ogni criterio. Con tutto a «Ignora» l'ordine resta quello di sempre: riproducibile, lingua, qualità, compatibilità.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            Section("Qualità") {
                weightPicker("Risoluzione", scoring.video)
                weightPicker("HDR e Dolby Vision", scoring.hdr)
                weightPicker("Audio (Atmos, TrueHD, DTS…)", scoring.audio)
            }
            Section {
                Picker("Dimensione", selection: scoring.size) { ForEach(SourceScoring.SizePreference.allCases, id: \.self) { Text($0.title).tag($0) } }
                if scoring.wrappedValue.size != .none { weightPicker("Peso della dimensione", scoring.sizeWeight, includeIgnore: false) }
                Picker("Codec", selection: scoring.codec) { ForEach(SourceScoring.CodecPreference.allCases, id: \.self) { Text($0.title).tag($0) } }
                if scoring.wrappedValue.codec != .any { weightPicker("Peso del codec", scoring.codecWeight, includeIgnore: false) }
            } header: { Text("Preferenze") } footer: {
                Text("HDR e audio vengono letti dal nome della release: sono etichette, non misure. Aether non può sapere cosa mostrerà davvero il tuo schermo finché il file non parte.")
            }
            Section {
                Button("Ripristina i criteri") { settings.value.playback.sourceScoring = SourceScoring() }
                    .disabled(scoring.wrappedValue.isNeutral)
            }
        }
        .navigationTitle("Intelligenza delle fonti")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func weightPicker(_ title: String, _ value: Binding<Int>, includeIgnore: Bool = true) -> some View {
        Picker(title, selection: value) {
            if includeIgnore { Text("Ignora").tag(0) }
            Text("Poco").tag(1)
            Text("Medio").tag(2)
            Text("Molto").tag(3)
        }
    }
}
