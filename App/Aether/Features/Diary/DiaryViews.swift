import SwiftUI
import AetherCore

/// Half-star rating (1...10) shown as five stars.
struct StarsView: View {
    let rating: Int?
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                let full = (rating ?? 0) >= (index + 1) * 2
                let half = !full && (rating ?? 0) == index * 2 + 1
                Image(systemName: full ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
                    .font(.caption2).foregroundStyle(rating == nil ? Color.aetherSecondary.opacity(0.4) : Color.yellow)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rating.map { "Voto \(Double($0) / 2) su 5" } ?? "Senza voto")
    }
}

// MARK: Diary

/// «Diario e statistiche»: the timeline of what was watched, with notes and ratings, and the numbers of each year.
struct DiaryView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryModel
    @State private var year: Int?
    @State private var editing: DiaryEntry?
    @State private var shownCount = 30

    private var diary: DiarySettings { return settings.value.content.diary }
    private var years: [Int] { return DiaryStats.years(diary.entries) }
    private var stats: DiaryStats { return DiaryStats.compute(diary.entries, year: year) }
    /// One dot of the timeline: a viewing written in the diary, or something watched with the player (finished or not).
    private struct Moment: Identifiable {
        var id: String
        var date: Date
        var name: String
        var poster: String?
        var type: String
        var metaID: String
        var detail: String
        var progress: Double
        var entry: DiaryEntry?
    }

    private var moments: [Moment] {
        let calendar = Calendar.current
        var list: [Moment] = diary.timeline.map { entry in
            Moment(id: entry.id, date: entry.watchedAt, name: entry.name, poster: entry.poster, type: entry.type, metaID: entry.metaID,
                   detail: entry.runtimeMinutes.map { "\($0 / 60)h \($0 % 60)m" } ?? "", progress: 1, entry: entry)
        }
        for item in library.history {
            // A viewing the diary already holds for the same title and day is not shown twice.
            if diary.entries.contains(where: { $0.metaID == item.metaID && calendar.isDate($0.watchedAt, inSameDayAs: item.updatedAt) }) { continue }
            let value = item.isCompleted ? 1 : item.fraction
            list.append(Moment(id: "h-" + item.id, date: item.updatedAt, name: item.title + (item.episodeLabel.map { " · \($0)" } ?? ""),
                               poster: item.poster, type: item.type, metaID: item.metaID, detail: "\(Int(value * 100))%", progress: value, entry: nil))
        }
        list.sort { $0.date > $1.date }
        guard let year = year else { return list }
        return list.filter { calendar.component(.year, from: $0.date) == year }
    }

    var body: some View {
        ZStack {
            AetherBackdrop()
            if diary.entries.isEmpty && library.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "book.closed").font(.system(size: 48)).foregroundStyle(Color.aetherSecondary)
                    Text("La timeline è vuota").font(.title3.weight(.bold))
                    Text("Quello che guardi nel player compare qui da solo. Con «Segna nel diario» sulla scheda di un titolo aggiungi data, voto e una nota; il segno di visto negli universi finisce qui.")
                        .font(.subheadline).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statsCard.padding(.horizontal, Theme.pageMargin)
                        timeline
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationTitle("Timeline di visione")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { entry in NavigationStack { DiaryEntryEditor(entry: entry) } }
    }

    private var timeline: some View {
        let items = moments
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "d MMM yyyy"
        let visible = Array(items.prefix(shownCount))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, moment in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10).padding(.top, 22)
                        Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 2).frame(maxHeight: .infinity)
                            .opacity(index == visible.count - 1 ? 0 : 1)
                    }
                    .frame(width: 12)
                    Button {
                        if let entry = moment.entry { editing = entry } else { router.detail = MetaRoute(type: moment.type, id: moment.metaID) }
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(urlString: moment.poster, width: 120, placeholderSeed: moment.name, systemPlaceholder: "film")
                                .frame(width: 50, height: 74).clipShape(RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(moment.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                Text("Visto il " + formatter.string(from: moment.date) + (moment.detail.isEmpty || moment.entry == nil ? "" : " · " + moment.detail))
                                    .font(.caption).foregroundStyle(Color.aetherSecondary)
                                if moment.entry != nil { StarsView(rating: moment.entry?.rating) }
                                if let note = moment.entry?.note, !note.isEmpty { Text(note).font(.footnote).lineLimit(2).foregroundStyle(Color.aetherSecondary) }
                            }
                            Spacer(minLength: 0)
                            ZStack {
                                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3)
                                Circle().trim(from: 0, to: moment.progress).stroke(moment.progress >= 1 ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                                if moment.progress >= 1 { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green) }
                                else { Text(moment.detail).font(.system(size: 9, weight: .bold)) }
                            }
                            .frame(width: 34, height: 34)
                        }
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { router.detail = MetaRoute(type: moment.type, id: moment.metaID) } label: { Label("Apri la scheda", systemImage: "info.circle") }
                        if let entry = moment.entry {
                            Button(role: .destructive) { settings.value.content.diary.remove(id: entry.id) } label: { Label("Elimina dal diario", systemImage: "trash") }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, Theme.pageMargin)
            }
            if items.count > shownCount {
                Button { shownCount += 30 } label: { Text("Visualizza tutta la cronologia").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12) }
                    .buttonStyle(SecondaryActionButtonStyle()).padding(.horizontal, Theme.pageMargin).padding(.top, 8)
            }
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Anno", selection: $year) {
                Text("Sempre").tag(Int?.none)
                ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                tile("\(stats.films)", "film")
                tile("\(stats.episodesAndSeries)", "serie")
                tile("\(stats.hours)", "ore")
                tile(stats.averageRating.map { String(format: "%.1f", $0) } ?? "–", "voto medio")
            }
            monthsChart
            if !stats.topGenres.isEmpty { chips("Generi più visti", stats.topGenres.map { "\($0.name) \($0.count)" }) }
            if !stats.topPeople.isEmpty { chips("Più presenti", stats.topPeople.map { "\($0.name) \($0.count)" }) }
            if stats.rewatches > 0 { Text("\(stats.rewatches) rewatch").font(.caption).foregroundStyle(Color.aetherSecondary) }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .padding(.vertical, 6)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(Color.aetherSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
    }

    private var monthsChart: some View {
        let peak = max(1, stats.perMonth.max() ?? 1)
        let letters = ["G", "F", "M", "A", "M", "G", "L", "A", "S", "O", "N", "D"]
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<12, id: \.self) { index in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(stats.perMonth[index] == 0 ? 0.15 : 0.9))
                        .frame(height: max(4, 46 * CGFloat(stats.perMonth[index]) / CGFloat(peak)))
                    Text(letters[index]).font(.system(size: 9)).foregroundStyle(Color.aetherSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Visioni per mese: " + stats.perMonth.map(String.init).joined(separator: ", "))
    }

    private func chips(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.aetherSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(items, id: \.self) { Text($0).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(Color.accentColor.opacity(0.18), in: Capsule()) } }
            }
        }
    }

    private func row(_ entry: DiaryEntry) -> some View {
        Button { editing = entry } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(urlString: entry.poster, width: 120, placeholderSeed: entry.name, systemPlaceholder: "film")
                    .frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.name).font(.headline).lineLimit(2)
                        if entry.rewatch { Image(systemName: "arrow.2.squarepath").font(.caption).foregroundStyle(Color.aetherSecondary).accessibilityLabel("Rewatch") }
                    }
                    Text(entry.watchedAt.formatted(date: .abbreviated, time: .omitted) + (entry.runtimeMinutes.map { " · \($0 / 60)h \($0 % 60)m" } ?? ""))
                        .font(.caption).foregroundStyle(Color.aetherSecondary)
                    StarsView(rating: entry.rating)
                    if !entry.note.isEmpty { Text(entry.note).font(.footnote).lineLimit(3).foregroundStyle(Color.aetherSecondary) }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { router.detail = MetaRoute(type: entry.type, id: entry.metaID) } label: { Label("Apri la scheda", systemImage: "info.circle") }
        }
    }
}

// MARK: Editor

/// Date, rating (half stars), note and rewatch of one viewing.
struct DiaryEntryEditor: View {
    @State var entry: DiaryEntry
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RemoteImage(urlString: entry.poster, width: 120, placeholderSeed: entry.name, systemPlaceholder: "film")
                        .frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                    Text(entry.name).font(.headline)
                }
                DatePicker("Visto il", selection: $entry.watchedAt, displayedComponents: [.date, .hourAndMinute])
                Toggle("Rewatch", isOn: $entry.rewatch)
            }
            Section("Il tuo voto") {
                HStack {
                    StarsView(rating: entry.rating)
                    Spacer()
                    Stepper(value: Binding(get: { entry.rating ?? 0 }, set: { entry.rating = $0 == 0 ? nil : $0 }), in: 0...10) {
                        Text(entry.rating.map { String(format: "%.1f / 5", Double($0) / 2) } ?? "Nessun voto").font(.subheadline.monospacedDigit())
                    }
                    .fixedSize()
                }
            }
            Section("Nota personale") {
                TextEditor(text: $entry.note).frame(minHeight: 110)
            }
            if settings.value.content.diary.entries.contains(where: { $0.id == entry.id }) {
                Section { Button("Elimina dal diario", role: .destructive) { settings.value.content.diary.remove(id: entry.id); dismiss() } }
            }
        }
        .navigationTitle("Diario")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { Button("Salva") { settings.value.content.diary.add(entry); dismiss() }.fontWeight(.semibold) }
        }
    }
}

/// «Segna nel diario» on a title page: the viewing is prefilled with what the page knows (genres, runtime, director, cast).
struct DiaryButton: View {
    let meta: MetaItem
    @EnvironmentObject private var settings: SettingsStore
    @State private var editing: DiaryEntry?

    private var latest: DiaryEntry? { return settings.value.content.diary.latest(for: meta.id) }

    var body: some View {
        Button {
            editing = latest.map { var copy = $0; copy.id = $0.id; return copy } ?? make()
        } label: {
            Label(latest == nil ? "Segna nel diario" : "Nel diario", systemImage: latest == nil ? "book" : "book.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.aetherSecondary)
        .accessibilityIdentifier("detail.diary")
        .contextMenu {
            if latest != nil { Button { editing = make() } label: { Label("Aggiungi un rewatch", systemImage: "arrow.2.squarepath") } }
        }
        .sheet(item: $editing) { entry in NavigationStack { DiaryEntryEditor(entry: entry) } }
    }

    private func make() -> DiaryEntry {
        let minutes = meta.runtime.flatMap { text -> Int? in
            let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return digits.first
        }
        return DiaryEntry(metaID: meta.id, type: meta.type, name: meta.name, poster: meta.poster, year: meta.releaseInfo.map { String($0.prefix(4)) }, genres: meta.genres,
                          runtimeMinutes: minutes, people: Array((meta.directors + meta.cast.prefix(3)).prefix(4)))
    }
}
