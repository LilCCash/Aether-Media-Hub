import SwiftUI
import AetherCore

/// The «more» of the player as a drop-down menu: speed, sleep timer, fill, sources, subtitles, information, companion, cinema mode.
/// SwiftUI compares `state` only (see `==`): the player redraws every half second, but this menu is rebuilt only when one of these values
/// changes, so it does not blink while it is open.
struct PlayerMoreMenu: View, Equatable {
    struct State: Equatable {
        var rate: Float
        var fill: Bool
        var cinema: Bool
        var alternatives: Bool
        var sharePlay: Bool
        var chat: Bool
        var sleeping: Bool
    }

    let model: PlayerViewModel
    let state: State
    let label: AnyView
    let identifier: String
    let openPanel: (PlayerPanel) -> Void
    let importSubtitle: () -> Void
    let show: (PlayerSheet) -> Void
    let toggleCinema: () -> Void

    static func == (lhs: PlayerMoreMenu, rhs: PlayerMoreMenu) -> Bool { return lhs.state == rhs.state }

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private let timers: [Int] = [15, 30, 45, 60, 90]

    var body: some View {
        Menu {
            Menu {
                ForEach(rates, id: \.self) { rate in
                    Button { model.setRate(rate) } label: {
                        Label(rate == 1 ? "Normale" : String(format: "%.2g×", Double(rate)), systemImage: state.rate == rate ? "checkmark" : "")
                    }
                }
            } label: { Label("Velocità", systemImage: "speedometer") }
            Menu {
                Button { model.setSleepTimer(minutes: nil) } label: { Label("Nessuno", systemImage: state.sleeping ? "" : "checkmark") }
                ForEach(timers, id: \.self) { minutes in
                    Button("\(minutes) minuti") { model.setSleepTimer(minutes: minutes) }
                }
            } label: { Label("Timer di spegnimento", systemImage: "moon.zzz") }
            Button { model.toggleFill() } label: {
                Label(state.fill ? "Adatta allo schermo" : "Riempi lo schermo",
                      systemImage: state.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Divider()
            if state.alternatives {
                Button { openPanel(.sources) } label: { Label("Cambia sorgente", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button { importSubtitle() } label: { Label("Importa sottotitoli…", systemImage: "doc.badge.plus") }
            Button { show(.info) } label: { Label("Informazioni sulla sorgente", systemImage: "info.circle") }
            if state.sharePlay {
                if state.chat {
                    Button { show(.chat) } label: { Label("Chat del cinema insieme", systemImage: "bubble.left.and.bubble.right") }
                } else {
                    Button { model.startWatchTogether() } label: { Label("Guarda insieme (SharePlay)", systemImage: "shareplay") }
                }
            }
            Divider()
            Button { show(.companion) } label: { Label("Companion: chi c'è nel film", systemImage: "person.2.crop.square.stack") }
            Button { toggleCinema() } label: { Label("Modalità Cinema", systemImage: state.cinema ? "checkmark" : "film") }
        } label: {
            label
        }
        .accessibilityIdentifier(identifier)
    }
}
