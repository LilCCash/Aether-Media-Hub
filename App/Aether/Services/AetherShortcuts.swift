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
    }
}
