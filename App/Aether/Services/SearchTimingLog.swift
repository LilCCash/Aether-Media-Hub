import Foundation
import AetherCore

/// Una ricerca avanzata e il tempo di ogni sua fase.
struct SearchTimingEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var query: String
    /// Chi ha interpretato la frase: parser, Apple Intelligence, un modello in rete, la memoria.
    var interpreter: String
    var total: Double
    var phases: [PhaseTiming]
    var results: Int
    var notes: [String]
}

/// Registro dei tempi della ricerca avanzata (Impostazioni ▸ Ricerca avanzata ▸ Registro dei tempi). Resta sul telefono.
@MainActor
final class SearchTimingLog: ObservableObject {
    static let limit = 40
    private static let defaultsKey = "aether.searchTimings.v1"

    @Published private(set) var entries: [SearchTimingEntry] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: SearchTimingLog.defaultsKey),
           let saved = try? JSONDecoder().decode([SearchTimingEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: SearchTimingEntry) {
        entries.insert(entry, at: 0)
        if entries.count > SearchTimingLog.limit { entries.removeLast(entries.count - SearchTimingLog.limit) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    /// Il registro come testo, da copiare e mandare.
    func text() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm:ss"
        return entries.map { entry -> String in
            var lines = ["\(formatter.string(from: entry.date)) · «\(entry.query)» · \(String(format: "%.2f", entry.total)) s · \(entry.results) risultati · \(entry.interpreter)"]
            for phase in entry.phases {
                lines.append("  - \(phase.name): \(String(format: "%.2f", phase.seconds)) s" + (phase.detail.map { " (\($0))" } ?? ""))
            }
            for note in entry.notes { lines.append("  ! \(note)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: SearchTimingLog.defaultsKey) }
    }
}
