import SwiftUI
import AetherCore

/// Impostazioni ▸ Ricerca avanzata: parole chiave, frasi in italiano e modelli di intelligenza artificiale (Apple Intelligence o chiave propria).
struct AdvancedSearchSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var sample = "film divertenti degli ultimi anni"
    @State private var testState: TestState = .idle
    @State private var appleStatus = AppleIntelligence.status

    private enum TestState: Equatable {
        case idle, running, ok
        case failed(String)
    }

    private var advanced: AdvancedSearchSettings { settings.value.content.advancedSearch }
    private var provider: AISearchProvider { advanced.provider }

    var body: some View {
        Form {
            generalSection
            if advanced.enabled {
                levelsSection
                if advanced.naturalParser { parserTrySection }
                if advanced.aiEnabled {
                    appleSection
                    providerSection
                    whenSection
                }
                resultsSection
                examplesSection
            }
        }
        .navigationTitle("Ricerca avanzata")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.advancedSearch")
        .onAppear { appleStatus = AppleIntelligence.status }
    }

    // MARK: Generale

    private var generalSection: some View {
        Section {
            Toggle("Attiva la ricerca avanzata", isOn: settings.binding(\.content.advancedSearch.enabled))
                .accessibilityIdentifier("advsearch.enabled")
            LabeledContent("Chiave TMDB") {
                Text(env.credentials.isConfigured(.tmdb) ? "Presente" : "Mancante")
                    .foregroundStyle(env.credentials.isConfigured(.tmdb) ? Color.green : Color.orange)
            }
        } footer: {
            Text("Scrivi cosa ti va di vedere («commedie demenziali famose», «horror italiani anni 80») e Aether lo trasforma in filtri su TMDB. I risultati compaiono in cima alla scheda Cerca. Serve la chiave TMDB (Impostazioni ▸ Servizi); il resto dipende dai livelli che scegli qui sotto.")
        }
    }

    // MARK: Livelli

    private var levelsSection: some View {
        Section {
            Toggle(isOn: settings.binding(\.content.advancedSearch.keywordSearch)) {
                levelLabel("1 · Parole chiave", "Cerca anche per tema («slasher», «heist», «viaggi nel tempo») usando le parole chiave di TMDB. Gratis, nessun servizio in più.")
            }
            .accessibilityIdentifier("advsearch.keyword")
            Toggle(isOn: settings.binding(\.content.advancedSearch.naturalParser)) {
                levelLabel("2 · Frasi in italiano (parser)", "Capisce in locale generi, anni, decenni, paesi e ordinamento («ultimi anni», «anni 80», «italiani», «migliori»). Gratis, senza AI e senza inviare la frase a nessuno tranne TMDB.")
            }
            .accessibilityIdentifier("advsearch.parser")
            Toggle(isOn: settings.binding(\.content.advancedSearch.aiEnabled)) {
                levelLabel("3 · Intelligenza artificiale", "Capisce frasi libere che il parser non conosce. Usa Apple Intelligence sul dispositivo e/o un modello in rete con la tua chiave.")
            }
            .accessibilityIdentifier("advsearch.ai")
        } header: {
            Text("Livelli di ricerca")
        } footer: {
            Text("Si possono accendere insieme: il parser lavora per primo; l'AI interviene secondo la regola scelta più sotto; le parole chiave completano ciò che resta.")
        }
    }

    private func levelLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.footnote).foregroundStyle(Color.aetherSecondary)
        }
    }

    private var parserTrySection: some View {
        Section {
            TextField("Scrivi una frase", text: $sample)
                .autocorrectionDisabled()
                .accessibilityIdentifier("advsearch.sample")
            let out = NaturalQueryParser().parse(sample)
            if out.intent.hasFilters {
                Label(out.intent.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Il parser non riconosce filtri in questa frase.", systemImage: "questionmark.circle").foregroundStyle(Color.aetherSecondary)
            }
            if !out.leftovers.isEmpty && advanced.keywordSearch {
                Text("Come parole chiave: " + out.leftovers.prefix(3).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
        } header: {
            Text("Prova il parser")
        } footer: {
            Text("Mostra come Aether legge la frase, senza fare ricerche.")
        }
    }

    // MARK: Apple Intelligence

    private var appleSection: some View {
        Section {
            Toggle("Usa Apple Intelligence", isOn: settings.binding(\.content.advancedSearch.useAppleIntelligence))
                .accessibilityIdentifier("advsearch.apple")
            Label(appleStatus.text, systemImage: appleStatus.isAvailable ? "apple.intelligence" : "exclamationmark.triangle")
                .foregroundStyle(appleStatus.isAvailable ? Color.green : Color.orange)
                .font(.footnote)
            if advanced.useAppleIntelligence {
                Toggle("Se non risponde, usa il modello in rete", isOn: settings.binding(\.content.advancedSearch.fallbackToProvider))
            }
        } header: {
            Text("Apple Intelligence (sul dispositivo)")
        } footer: {
            Text("Il modello di Apple gira sull'iPhone: gratis, anche offline, e la frase non lascia il telefono. Richiede iOS 26 e un iPhone con Apple Intelligence attiva. Se è spenta o non basta, Aether passa al modello in rete (se lo hai configurato) o al solo parser.")
        }
    }

    // MARK: Modello in rete

    private var providerSection: some View {
        Group {
            Section {
                Picker("Servizio", selection: settings.binding(\.content.advancedSearch.provider)) {
                    ForEach(AISearchProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("advsearch.provider")
                TextField("Nome del modello", text: modelBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("advsearch.model")
                if !provider.suggestedModels.isEmpty {
                    Menu("Modelli consigliati") {
                        ForEach(provider.suggestedModels, id: \.self) { name in
                            Button(name) { settings.value.content.advancedSearch.setModel(name, for: provider) }
                        }
                    }
                }
                if provider == .custom {
                    TextField("Indirizzo (https://…/v1)", text: settings.binding(\.content.advancedSearch.customBaseURL))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("advsearch.baseurl")
                }
            } header: {
                Text("Modello in rete")
            } footer: {
                Text(providerFooter)
            }
            AIKeySection(provider: provider, credentials: env.credentials)
            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Text("Prova il modello")
                        if testState == .running { Spacer(); ProgressView() }
                    }
                }
                .disabled(testState == .running)
                .accessibilityIdentifier("advsearch.test")
                switch testState {
                case .ok: Label("Il modello risponde.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                default: EmptyView()
                }
            } footer: {
                Text("Invia al modello una frase di prova per controllare chiave e nome. Può consumare una frazione di centesimo di credito.")
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.value.content.advancedSearch.model(for: provider) },
                set: { settings.value.content.advancedSearch.setModel($0, for: provider) })
    }

    private var providerFooter: String {
        switch provider {
        case .anthropic: return "Consigliato un modello piccolo e veloce come Claude Haiku: basta e costa poco. La chiave si crea su console.anthropic.com."
        case .openai: return "Un modello «mini» basta. La chiave si crea su platform.openai.com."
        case .google: return "Un modello «flash» basta. La chiave si crea su aistudio.google.com."
        case .openrouter: return "OpenRouter dà accesso a molti modelli con una sola chiave (openrouter.ai). Il nome ha la forma «fornitore/modello»."
        case .custom: return "Qualsiasi server con API compatibile OpenAI raggiungibile via https (la chiave è facoltativa). I server nella rete di casa non sono raggiungibili: Aether blocca gli indirizzi privati."
        }
    }

    private func runTest() async {
        testState = .running
        let year = Calendar.current.component(.year, from: Date())
        if let error = await env.advancedSearch.ai.test(settings: settings.value.content.advancedSearch, year: year) {
            testState = .failed(error.message)
        } else {
            testState = .ok
        }
    }

    // MARK: Quando

    private var whenSection: some View {
        Section {
            Picker("Interroga l'AI", selection: settings.binding(\.content.advancedSearch.aiTrigger)) {
                ForEach(AISearchTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Intervento dell'AI", selection: settings.binding(\.content.advancedSearch.aiMode)) {
                ForEach(AISearchMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Stepper("Attesa massima: \(advanced.aiTimeout) s", value: settings.binding(\.content.advancedSearch.aiTimeout), in: 5...60, step: 5)
        } header: {
            Text("Quando usare l'AI")
        } footer: {
            Text("«Premendo Cerca» fa una sola richiesta per ricerca (meno consumo di chiave). «Solo se il parser non capisce» risparmia richieste: l'AI interviene soltanto sulle frasi che il parser non sa leggere.")
        }
    }

    // MARK: Risultati

    private var resultsSection: some View {
        Section {
            Picker("Cerca tra", selection: settings.binding(\.content.advancedSearch.resultKind)) {
                ForEach(AdvancedResultKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Stepper("Risultati: \(advanced.maxResults)", value: settings.binding(\.content.advancedSearch.maxResults), in: 5...40, step: 5)
            Stepper("Voti minimi per «migliori»: \(advanced.minVotes)", value: settings.binding(\.content.advancedSearch.minVotes), in: 0...5000, step: 100)
            Toggle("Mostra come ho letto la frase", isOn: settings.binding(\.content.advancedSearch.showInterpretation))
            Toggle("Mostra chi l'ha interpretata", isOn: settings.binding(\.content.advancedSearch.showSource))
            Toggle("Includi contenuti per adulti", isOn: settings.binding(\.content.advancedSearch.includeAdult))
            Toggle("Ricorda le frasi già interpretate", isOn: settings.binding(\.content.advancedSearch.rememberInterpretations))
            Button("Svuota le frasi ricordate", role: .destructive) { env.advancedSearch.clearCache() }
        } header: {
            Text("Risultati")
        } footer: {
            Text("Per sapere quali titoli sono «migliori» Aether ignora quelli con pochissimi voti: alza il numero per essere più selettivo. Ricordare le frasi evita di richiamare l'AI per la stessa ricerca.")
        }
    }

    private var examplesSection: some View {
        Section {
            ForEach(["film divertenti degli ultimi anni", "commedie demenziali famose", "horror italiani anni 80", "migliori serie thriller", "heist movie recenti"], id: \.self) { example in
                Text("«\(example)»").font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
        } header: {
            Text("Esempi")
        }
    }
}

/// La chiave del servizio AI scelto, nel Portachiavi come le altre.
private struct AIKeySection: View {
    let provider: AISearchProvider
    @ObservedObject var credentials: ServiceCredentials
    @State private var draft = ""

    private var kind: ServiceKind { ServiceKind.ai(provider) }

    var body: some View {
        Section {
            if credentials.isConfigured(kind) {
                Label("Chiave salvata nel Portachiavi", systemImage: "key.fill")
                Button("Rimuovi la chiave", role: .destructive) { credentials.remove(kind) }
                    .accessibilityIdentifier("advsearch.key.remove")
            } else {
                SecureField(provider.keyIsOptional ? "Chiave (facoltativa)" : "Chiave API", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("advsearch.key")
                Button("Salva la chiave") {
                    try? credentials.save(draft, for: kind)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Chiave di \(provider.title)")
        } footer: {
            Text("La chiave resta nel Portachiavi di questo iPhone (mai nei log). La frase che scrivi viene inviata a \(provider.title) solo quando l'AI interviene.")
        }
    }
}
