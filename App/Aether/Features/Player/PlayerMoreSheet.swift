import SwiftUI
import AetherCore

/// The «more» of the player: speed, sleep timer, fill, sources, subtitles, information, companion and cinema mode. It is a sheet, not a menu: a menu
/// opened over a player that redraws itself every half second blinks, a sheet of plain buttons does not.
struct PlayerMoreSheet: View {
    @ObservedObject var model: PlayerViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let openPanel: (PlayerPanel) -> Void
    let importSubtitle: () -> Void
    let show: (PlayerSheet) -> Void

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private let timers: [Int?] = [nil, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                Section("Riproduzione") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Velocità").font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            ForEach(rates, id: \.self) { rate in
                                Button { model.setRate(rate) } label: {
                                    Text(rate == 1 ? "1×" : String(format: "%.2g×", Double(rate)))
                                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(model.playbackRate == rate ? Color.accentColor : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .foregroundStyle(model.playbackRate == rate ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Timer di spegnimento").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let remaining = model.sleepRemaining { Text(Format.duration(remaining)).font(.caption.monospacedDigit()).foregroundStyle(Color.aetherSecondary) }
                        }
                        HStack(spacing: 6) {
                            ForEach(Array(timers.enumerated()), id: \.offset) { _, minutes in
                                Button { model.setSleepTimer(minutes: minutes) } label: {
                                    Text(minutes.map { "\($0)′" } ?? "No").font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Button { model.toggleFill() } label: {
                        Label(model.isFill ? "Adatta allo schermo" : "Riempi lo schermo", systemImage: model.isFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                Section("Fonti e sottotitoli") {
                    if !model.alternatives.isEmpty {
                        Button { dismiss(); openPanel(.sources) } label: { Label("Cambia sorgente", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    Button { dismiss(); importSubtitle() } label: { Label("Importa sottotitoli…", systemImage: "doc.badge.plus") }
                    Button { show(.info) } label: { Label("Informazioni sulla sorgente", systemImage: "info.circle") }
                    if model.sharePlayAvailable {
                        Button { dismiss(); model.startWatchTogether() } label: { Label("Guarda insieme (SharePlay)", systemImage: "shareplay") }
                    }
                }
                Section("Per goderti il film") {
                    Button { show(.companion) } label: { Label("Companion: chi c'è nel film", systemImage: "person.2.crop.square.stack") }
                    Toggle(isOn: settings.binding(\.playback.cinemaMode)) { Label("Modalità Cinema", systemImage: "film") }
                }
            }
            .navigationTitle("Opzioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
