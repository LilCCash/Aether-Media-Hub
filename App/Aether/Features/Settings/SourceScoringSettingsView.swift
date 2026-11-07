import SwiftUI
import AetherCore

/// Settings ▸ Intelligenza delle fonti: what counts when Aether orders the sources of a title. Everything here only changes the order
/// (a source that cannot be played stays at the bottom whatever the weights say).
struct SourceScoringSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore

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
                Toggle("Impara da come vanno le riproduzioni", isOn: scoring.learnsFromPlayback)
                ForEach(learned, id: \.id) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text(row.bonus > 0 ? "affidabile" : (row.bonus < 0 ? "problemi frequenti" : "in prova"))
                            .font(.footnote).foregroundStyle(row.bonus > 0 ? Color.green : (row.bonus < 0 ? Color.orange : Color.aetherSecondary))
                    }
                }
                if !scoring.wrappedValue.reliability.isEmpty {
                    Button("Dimentica quello che ha imparato", role: .destructive) { settings.value.playback.sourceScoring.reliability = SourceReliability() }
                }
            } header: { Text("Apprendimento") } footer: {
                Text("Se le sorgenti di un addon partono quasi sempre salgono nella lista, se spesso falliscono scendono. Resta tutto sul telefono e conta solo dopo almeno tre riproduzioni.")
            }
            Section {
                Button("Ripristina i criteri") {
                    var fresh = SourceScoring()
                    fresh.learnsFromPlayback = settings.value.playback.sourceScoring.learnsFromPlayback
                    fresh.reliability = settings.value.playback.sourceScoring.reliability
                    settings.value.playback.sourceScoring = fresh
                }
                .disabled(scoring.wrappedValue.isNeutral)
            }
        }
        .navigationTitle("Intelligenza delle fonti")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var learned: [(id: String, name: String, bonus: Int)] {
        let rel = settings.value.playback.sourceScoring.reliability
        return rel.tallies.keys.sorted().map { key in
            (key, addons.addons.first { $0.id.uuidString == key }?.displayName ?? "Addon rimosso", rel.bonus(addonID: key))
        }
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
