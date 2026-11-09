import AppIntents

/// «Cerca in Aether»: asks what to look for and opens the Search tab with it.
struct SearchInAetherIntent: AppIntent {
    static var title: LocalizedStringResource = "Cerca in Aether"
    static var description = IntentDescription("Cerca un film o una serie in Aether.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Titolo", requestValueDialog: "Cosa vuoi cercare?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.receive("search:" + query)
        return .result()
    }
}

/// «Riprendi in Aether»: opens the Home, where «Continua a guardare» is.
struct ContinueWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continua a guardare"
    static var description = IntentDescription("Apre Aether sui titoli che stai guardando.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.receive("app.aether.continue")
        return .result()
    }
}

/// «Riprendi l'ultimo»: opens the title that was watched last, on its page (one tap from playing).
struct ResumeLastIntent: AppIntent {
    static var title: LocalizedStringResource = "Riprendi l'ultimo titolo"
    static var description = IntentDescription("Apre l'ultimo film o episodio che stavi guardando.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.receive("app.aether.resume")
        return .result()
    }
}

/// «Cerca titoli simili a…»: the advanced search ("film simili a Toy Story") with the title already written.
struct SimilarToIntent: AppIntent {
    static var title: LocalizedStringResource = "Cerca titoli simili"
    static var description = IntentDescription("Cerca film e serie simili a un titolo.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Titolo", requestValueDialog: "Simili a quale titolo?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.receive("search:film simili a " + name)
        return .result()
    }
}

/// «Aggiungi alla watchlist di Aether»: asks which title, finds it in the addons, adds it and opens its page.
struct AddToWatchlistIntent: AppIntent {
    static var title: LocalizedStringResource = "Aggiungi alla watchlist"
    static var description = IntentDescription("Cerca un film o una serie e lo aggiunge alla tua watchlist di Aether.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Titolo", requestValueDialog: "Quale titolo aggiungo alla watchlist?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.receive("watchlist:" + name)
        return .result()
    }
}

/// «Apri la scheda in Aether»: asks which title and opens its page.
struct OpenTitleIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri la scheda di un titolo"
    static var description = IntentDescription("Cerca un film o una serie e ne apre la scheda in Aether.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Titolo", requestValueDialog: "Di quale titolo apro la scheda?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.receive("open:" + name)
        return .result()
    }
}

/// The phrases iOS knows without the viewer setting anything up; they also show in Spotlight and in the Shortcuts app.
struct AetherShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchInAetherIntent(),
                    phrases: ["Cerca in \(.applicationName)", "Cerca un film in \(.applicationName)"],
                    shortTitle: "Cerca",
                    systemImageName: "magnifyingglass")
        AppShortcut(intent: ContinueWatchingIntent(),
                    phrases: ["Riprendi in \(.applicationName)", "Continua a guardare in \(.applicationName)"],
                    shortTitle: "Continua a guardare",
                    systemImageName: "play.circle.fill")
        AppShortcut(intent: ResumeLastIntent(),
                    phrases: ["Riprendi l'ultimo in \(.applicationName)", "Riprendi dove ero in \(.applicationName)"],
                    shortTitle: "Riprendi l'ultimo",
                    systemImageName: "backward.end.fill")
        AppShortcut(intent: AddToWatchlistIntent(),
                    phrases: ["Aggiungi alla watchlist di \(.applicationName)", "Aggiungi un titolo alla watchlist di \(.applicationName)"],
                    shortTitle: "Aggiungi alla watchlist",
                    systemImageName: "bookmark")
        AppShortcut(intent: OpenTitleIntent(),
                    phrases: ["Apri la scheda in \(.applicationName)", "Apri un titolo in \(.applicationName)"],
                    shortTitle: "Apri la scheda",
                    systemImageName: "film")
        AppShortcut(intent: SimilarToIntent(),
                    phrases: ["Cerca titoli simili in \(.applicationName)", "Cerca qualcosa di simile in \(.applicationName)"],
                    shortTitle: "Cerca titoli simili",
                    systemImageName: "sparkle.magnifyingglass")
    }
}
