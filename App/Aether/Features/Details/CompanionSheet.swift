import SwiftUI
import AetherCore

/// Companion: a friendly page about the film being watched: the faces, who made it, where it sits in its universe, and, with the viewer's own
/// AI key, a box to ask anything about it (answers keep to the spoiler level chosen). Facts come from the metadata and from Aether's universes.
struct CompanionSheet: View {
    let meta: MetaItem
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("aether.pro.companion.level") private var levelRaw = SpoilerLevel.none.rawValue
    @State private var rich: TitleRichDetails?
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var problem: String?

    private var level: SpoilerLevel { return SpoilerLevel(rawValue: levelRaw) ?? .none }
    private var advanced: AdvancedSearchSettings { return settings.value.content.advancedSearch }
    private var canAsk: Bool { return env.advancedSearch.ai.hasKey(for: advanced.provider) || advanced.provider.keyIsOptional }
    private var watched: Set<String> { return Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys) }

    private func emoji(_ level: SpoilerLevel) -> String {
        switch level {
        case .none: return "🙈"
        case .context: return "🍿"
        case .deep: return "🔦"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero
                        levelPicker
                        if let people = rich?.cast, !people.isEmpty { castRow(people) }
                        ForEach(CompanionPlanner.cards(for: meta, level: level, watched: watched)) { card in cardView(card) }
                        universeStrip
                        assistant
                        Text("Tutto viene dai dati dell'addon, da TMDB e dagli universi di Aether: niente curiosità inventate. Le risposte dell'AI, se le chiedi, sono sue.")
                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
            .task { await loadRich() }
        }
        .presentationDetents([.large])
    }

    // MARK: Parts

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: meta.background ?? meta.poster, width: 900, contentMode: .fill, placeholderSeed: meta.name)
                .frame(height: 170).frame(maxWidth: .infinity).clipped()
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 12) {
                RemoteImage(urlString: meta.poster, width: 200, placeholderSeed: meta.name)
                    .frame(width: 74, height: 74 / CGFloat(meta.posterShape.aspectRatio))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("🍿 Ciao! Ecco chi c'è dietro e dentro").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    Text(meta.name).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2)
                    Text([meta.releaseInfo, meta.runtime].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SpoilerLevel.allCases, id: \.rawValue) { item in
                    Button { withAnimation(.snappy) { levelRaw = item.rawValue } } label: {
                        VStack(spacing: 2) {
                            Text(emoji(item)).font(.title3)
                            Text(item.title).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(level == item ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(level == item ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(level == item ? .isSelected : [])
                }
            }
            Text(level.explanation).font(.caption).foregroundStyle(Color.aetherSecondary)
        }
    }

    private func castRow(_ people: [TitleRichDetails.Person]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🎭 Le facce del film").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(people.prefix(14).enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 5) {
                            RemoteImage(urlString: person.photoURL, width: 180, placeholderSeed: person.name, systemPlaceholder: "person.fill")
                                .frame(width: 66, height: 66).clipShape(Circle())
                                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2))
                            Text(person.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            if let role = person.role { Text(role).font(.caption2).foregroundStyle(Color.aetherSecondary).lineLimit(2).multilineTextAlignment(.center) }
                        }
                        .frame(width: 84)
                    }
                }
            }
        }
    }

    private func icon(for id: String) -> (String, Color, String) {
        switch id {
        case "basics": return ("film.fill", .blue, "🎞️ Il titolo")
        case "directors": return ("megaphone.fill", .orange, "🎬 Dietro la macchina da presa")
        case "writers": return ("pencil.and.scribble", .pink, "✍️ Chi l'ha scritto")
        case "cast": return ("person.2.fill", .purple, "🎭 Interpreti principali")
        case "universe": return ("sparkles", .indigo, "🌌 Nel suo universo")
        case "production": return ("trophy.fill", .yellow, "🏆 Produzione e premi")
        case "around": return ("arrow.left.arrow.right", .teal, "↔️ Prima e dopo")
        default: return ("text.alignleft", .gray, "📜 Trama (dall'addon)")
        }
    }

    private func cardView(_ card: CompanionCard) -> some View {
        let style = icon(for: card.id)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.0).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(style.1.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(card.id == "directors" ? (meta.directors.count > 1 ? "🎬 Registi" : style.2) : style.2).font(.headline)
                ForEach(card.lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Color.primary.opacity(0.85)) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    /// The titles around this one in its universe, as posters to open.
    @ViewBuilder
    private var universeStrip: some View {
        let universes = UniverseCatalog.universes(containing: meta.id)
        if level.rawValue >= SpoilerLevel.deep.rawValue, !universes.isEmpty {
            ForEach(universes) { universe in
                let release = universe.ordered(.release)
                if let index = release.firstIndex(where: { $0.id == meta.id }) {
                    let around = [index > 0 ? release[index - 1] : nil, index + 1 < release.count ? release[index + 1] : nil].compactMap { $0 }
                    if !around.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("🌌 \(universe.name): i titoli vicini").font(.headline)
                            HStack(spacing: 14) {
                                ForEach(around) { entry in
                                    Button {
                                        dismiss()
                                        router.detail = MetaRoute(type: entry.type, id: entry.id, preview: MetaItem(id: entry.id, type: entry.type, name: entry.name, poster: UniverseArt.poster(entry.id)))
                                    } label: {
                                        VStack(spacing: 5) {
                                            ZStack(alignment: .bottomTrailing) {
                                                RemoteImage(urlString: UniverseArt.poster(entry.id), width: 240, placeholderSeed: entry.name)
                                                    .frame(width: 92, height: 138).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                                if watched.contains(entry.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green, .white).padding(5) }
                                            }
                                            Text(entry.id == release[index - (index > 0 ? 1 : 0)].id && index > 0 ? "Prima" : "Dopo").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                                            Text(entry.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center).frame(width: 92)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Assistant

    @ViewBuilder
    private var assistant: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("💬 Chiedi a Aether").font(.headline)
            if canAsk {
                HStack(spacing: 8) {
                    TextField("Es. chi è il cattivo? Dove è girato?", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                        .submitLabel(.send).onSubmit { Task { await ask() } }
                    Button { Task { await ask() } } label: {
                        if asking { ProgressView() } else { Image(systemName: "paperplane.fill") }
                    }
                    .buttonStyle(.borderedProminent).disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Risponde al livello «\(level.title)»: " + (level == .none ? "senza svelare la trama." : level == .context ? "senza rovinare il finale." : "può svelare la storia."))
                    .font(.caption).foregroundStyle(Color.aetherSecondary)
                if let answer = answer { Text(answer).font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                if let problem = problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Per fare domande sul film serve una chiave di un servizio AI (Claude, OpenAI, Google, OpenRouter…): inseriscila in Impostazioni ▸ Ricerca avanzata. Resta tua e viene usata solo per le tue domande.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func ask() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        problem = nil
        defer { asking = false }
        let rule: String
        switch level {
        case .none: rule = "Non rivelare nulla della trama oltre la sinossi data, nemmeno indizi sul finale o su morti e tradimenti."
        case .context: rule = "Puoi parlare di produzione e contesto, ma non rovinare il finale né le svolte importanti."
        case .deep: rule = "Puoi parlare liberamente della storia, anche con spoiler."
        }
        let facts = [
            "Titolo: " + meta.name + " (" + (meta.releaseInfo ?? "anno sconosciuto") + ")",
            meta.directors.isEmpty ? nil : "Regia: " + meta.directors.joined(separator: ", "),
            meta.cast.isEmpty ? nil : "Cast: " + meta.cast.prefix(8).joined(separator: ", "),
            meta.genres.isEmpty ? nil : "Generi: " + meta.genres.joined(separator: ", "),
            meta.description.map { "Sinossi: " + $0 },
        ].compactMap { $0 }.joined(separator: "\\n")
        let system = "Sei il compagno cinematografico di un'app per guardare film. Rispondi in italiano, in modo simpatico e breve (al massimo cinque frasi). \(rule) Se non sei sicuro di un fatto, dillo invece di inventare. Dati sul titolo:\\n\(facts)"
        do {
            answer = try await env.advancedSearch.ai.ask(text, system: system, settings: advanced)
        } catch let error as AISearchError {
            problem = error.message
        } catch {
            problem = "Non riesco a contattare il servizio AI."
        }
    }

    private func loadRich() async {
        guard rich == nil else { return }
        let language = MetadataEnricher.tmdbLanguage(preferred: settings.value.content.preferredLanguage)
        rich = await env.metadata.richDetails(for: meta, language: language)
    }
}

/// «Companion» button for a title page.
struct CompanionButton: View {
    let meta: MetaItem
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: { Label("Companion", systemImage: "person.2.crop.square.stack").font(.subheadline.weight(.semibold)) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("detail.companion")
            .sheet(isPresented: $shown) { CompanionSheet(meta: meta) }
    }
}
