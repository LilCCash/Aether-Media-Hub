import SwiftUI
import AetherCore

/// What the viewer has watched, counted from the library's history (nothing leaves the phone).
struct StatsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var rows: [PlaybackProgress] = []
    @State private var loaded = false

    private static func seconds(_ row: PlaybackProgress) -> Double {
        return row.isCompleted ? max(row.duration, row.position) : row.position
    }

    private func total(since days: Int? = nil) -> Double {
        let from = days.map { Date().addingTimeInterval(-Double($0) * 86400) }
        return rows.filter { row in from.map { row.updatedAt >= $0 } ?? true }.reduce(0) { $0 + StatsView.seconds($1) }
    }

    static func format(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours >= 100 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }

    private struct TitleTime: Identifiable {
        let id: String
        let title: String
        var seconds: Double
    }

    private var topTitles: [TitleTime] {
        var byTitle: [String: TitleTime] = [:]
        for row in rows {
            var current = byTitle[row.metaID] ?? TitleTime(id: row.metaID, title: row.title, seconds: 0)
            current.seconds += StatsView.seconds(row)
            byTitle[row.metaID] = current
        }
        return Array(byTitle.values.sorted { $0.seconds > $1.seconds }.prefix(5))
    }

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Section {
                    Text("Non c'è ancora niente da contare: guarda qualcosa e torna qui.").foregroundStyle(.secondary)
                }
            } else if loaded {
                Section(header: Text("In totale")) {
                    LabeledContent("Tempo di visione", value: StatsView.format(total()))
                    LabeledContent("Film completati", value: "\(rows.filter { $0.isCompleted && $0.type == "movie" }.count)")
                    LabeledContent("Episodi completati", value: "\(rows.filter { $0.isCompleted && $0.type != "movie" }.count)")
                    LabeledContent("Serie seguite", value: "\(Set(rows.filter { $0.type != "movie" }.map { $0.metaID }).count)")
                }
                Section(header: Text("Di recente")) {
                    LabeledContent("Ultimi 7 giorni", value: StatsView.format(total(since: 7)))
                    LabeledContent("Ultimi 30 giorni", value: StatsView.format(total(since: 30)))
                }
                Section(header: Text("I più guardati")) {
                    ForEach(topTitles) { item in
                        LabeledContent(item.title, value: StatsView.format(item.seconds))
                    }
                }
            }
        }
        .navigationTitle("Statistiche")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            rows = await env.libraryStore.history(limit: 100_000)
            loaded = true
        }
    }
}
