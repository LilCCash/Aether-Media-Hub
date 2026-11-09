import SwiftUI
import AetherCore

/// Impostazioni ▸ Ricerca avanzata: parole chiave, frasi in italiano e modelli di intelligenza artificiale (Apple Intelligence o chiave propria).
struct AdvancedSearchSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var sample = "film divertenti degli ultimi anni"
    @State private var testState: TestState = .idle
    @State private var appleStatus = AppleIntelligence.status
    @State private var models: [AIModelInfo] = []
    @State private var modelsState: ModelsState = .idle

    private enum ModelsState: Equatable {
        case idle, loading
        case loaded(Int)
        case failed(String)
    }

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
                    engineSection
                    if advanced.aiEngine != .appleOnly { providerSection }
                    whenSection
                }
                resultsSection
                timingSection
                examplesSection
            }
        }
        .aetherPage()
        .navigationTitle("Ricerca avanzata")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.advancedSearch")
        .onAppear { appleStatus = AppleIntelligence.status }
        .task(id: provider) { models = []; modelsState = .idle; await loadModels(auto: true) }
        .onReceive(env.credentials.$configured) { _ in Task { await loadModels(auto: true) } }
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

    // MARK: Motore

    private var engineSection: some View {
        Section {
            Picker("Chi risponde", selection: settings.binding(\.content.advancedSearch.aiEngine)) {
                ForEach(AIEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("advsearch.engine")
            Label(appleStatus.text, systemImage: appleStatus.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(appleStatus.isAvailable ? Color.green : Color.orange)
                .font(.footnote)
            Toggle(isOn: settings.binding(\.content.advancedSearch.aiSuggestsTitles)) {
                levelLabel("L'AI propone i titoli", "Oltre a capire la frase, l'AI sceglie lei i titoli («film simili a Toy Story»): Aether li ritrova su TMDB. Senza questa opzione l'AI traduce solo la frase in filtri e parole chiave.")
            }
            .accessibilityIdentifier("advsearch.suggest")
        } header: {
            Text("Motore dell'intelligenza artificiale")
        } footer: {
            Text("Apple Intelligence gira sull'iPhone: gratis e privata, ma è un modello piccolo e non sempre conosce i titoli. Il modello in rete (con la tua chiave) è molto più preparato sui film: scegli «Solo modello in rete» per usarlo direttamente, senza passare da Apple Intelligence.")
        }
    }

    // MARK: Modello in rete

    private var currentKind: ServiceKind { ServiceKind.ai(provider) }
    private var keyPresent: Bool { env.credentials.isConfigured(currentKind) }

    private var providerSection: some View {
        Group {
            Section {
                Picker("Servizio", selection: settings.binding(\.content.advancedSearch.provider)) {
                    ForEach(AISearchProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("advsearch.provider")
                if provider == .custom {
                    TextField("Indirizzo (https://…/v1)", text: settings.binding(\.content.advancedSearch.customBaseURL))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("advsearch.baseurl")
                }
                AIKeyGuide(provider: provider)
            } header: {
                Text("Modello in rete")
            }
            AIKeySection(provider: provider, credentials: env.credentials)
            Section {
                Button {
                    Task { await loadModels(auto: false) }
                } label: {
                    HStack {
                        Text("Verifica la chiave")
                        if modelsState == .loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(modelsState == .loading || (!keyPresent && !provider.keyIsOptional && provider != .openrouter))
                .accessibilityIdentifier("advsearch.verify")
                switch modelsState {
                case .loaded(let count):
                    Label(keyPresent ? "Chiave valida: \(count) modelli disponibili con il tuo piano." : "\(count) modelli disponibili.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                default:
                    EmptyView()
                }
                modelRow
            } header: {
                Text("Chiave e modello")
            } footer: {
                Text("«Verifica la chiave» chiede al servizio l'elenco dei modelli: è gratuito, non consuma credito. L'elenco dipende dal piano dell'account collegato alla chiave. Se per questo servizio il modello è già scelto, resta quello finché non ne scegli un altro.")
            }
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
                Text("Invia al modello una vera richiesta di prova («film simili a Toy Story»): costa una frazione di centesimo.")
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if !models.isEmpty {
            NavigationLink {
                AIModelPickerView(models: models, selection: modelBinding)
            } label: {
                LabeledContent("Modello", value: displayName(of: advanced.model(for: provider)))
            }
            .accessibilityIdentifier("advsearch.model")
        } else if provider == .custom {
            TextField("Nome del modello", text: modelBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("advsearch.model")
        } else {
            LabeledContent("Modello", value: displayName(of: advanced.model(for: provider)))
            Text("Salva e verifica la chiave per scegliere tra i modelli disponibili.")
                .font(.footnote).foregroundStyle(Color.aetherSecondary)
        }
    }

    private func displayName(of id: String) -> String {
        return models.first(where: { $0.id == id })?.name ?? (id.isEmpty ? "Nessuno" : id)
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.value.content.advancedSearch.model(for: provider) },
                set: { settings.value.content.advancedSearch.setModel($0, for: provider) })
    }

    /// Legge i modelli che la chiave può usare. In automatico (cambio servizio, chiave appena salvata) non mostra errori.
    private func loadModels(auto: Bool) async {
        let current = provider
        let canTry = keyPresent || provider.keyIsOptional || provider == .openrouter
        guard canTry else {
            if !auto { modelsState = .failed("Prima salva la chiave.") }
            return
        }
        if auto && modelsState == .loading { return }
        modelsState = .loading
        do {
            let list = try await env.advancedSearch.ai.listModels(provider: current, customBase: advanced.customBaseURL)
            guard current == provider else { return }
            models = list
            modelsState = .loaded(list.count)
            // Se il modello scelto non è più disponibile con questo piano, si propone il primo consigliato.
            let chosen = advanced.model(for: current)
            if !list.contains(where: { $0.id == chosen }) {
                let preferred = list.first(where: { $0.id == current.defaultModel }) ?? list.first
                if let preferred = preferred { settings.value.content.advancedSearch.setModel(preferred.id, for: current) }
            }
        } catch let error as AISearchError {
            guard current == provider else { return }
            models = []
            modelsState = auto ? .idle : .failed(error.message)
        } catch {
            modelsState = auto ? .idle : .failed("Errore di rete.")
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

    private var timingSection: some View {
        Section {
            Toggle("Registra i tempi", isOn: settings.binding(\.content.advancedSearch.logTimings))
                .accessibilityIdentifier("advsearch.logTimings")
            NavigationLink {
                SearchTimingLogView()
            } label: {
                LabeledContent("Registro dei tempi", value: "\(env.searchTimings.entries.count)")
            }
            .accessibilityIdentifier("advsearch.timings")
        } header: {
            Text("Velocità")
        } footer: {
            Text("Per ogni ricerca segna quanto ci hanno messo l'AI e TMDB, fase per fase: così si vede chi è lento. Il registro resta sul telefono (ultime 40 ricerche) e si può copiare. Aether ricorda anche i titoli già ritrovati, quindi le ricerche ripetute sono più veloci.")
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


/// Come ottenere la chiave del servizio scelto, passo per passo.
private struct AIKeyGuide: View {
    let provider: AISearchProvider

    private struct Guide {
        let url: String
        let linkTitle: String
        let steps: [String]
        let cost: String
    }

    private var guide: Guide {
        switch provider {
        case .anthropic:
            return Guide(url: "https://console.anthropic.com/settings/keys", linkTitle: "console.anthropic.com",
                         steps: ["Crea un account sulla console Anthropic (è diversa dall'app Claude).", "Apri Settings ▸ API keys ▸ Create Key e dai un nome alla chiave.", "Copia la chiave (inizia con «sk-ant-»): viene mostrata una volta sola.", "In Billing aggiungi del credito: l'API è a consumo."],
                         cost: "L'abbonamento Claude Pro/Max non include l'API. Qui una ricerca costa frazioni di centesimo con un modello Haiku.")
        case .openai:
            return Guide(url: "https://platform.openai.com/api-keys", linkTitle: "platform.openai.com",
                         steps: ["Accedi a platform.openai.com (è separato da ChatGPT).", "Apri API keys ▸ Create new secret key.", "Copia la chiave (inizia con «sk-»): viene mostrata una volta sola.", "In Billing aggiungi credito prepagato, altrimenti le richieste vengono rifiutate."],
                         cost: "ChatGPT Plus non include l'API. Un modello «mini» costa pochissimo per richieste così corte.")
        case .google:
            return Guide(url: "https://aistudio.google.com/apikey", linkTitle: "aistudio.google.com",
                         steps: ["Accedi a Google AI Studio con il tuo account Google.", "Apri «Get API key» ▸ Create API key.", "Copia la chiave e incollala qui sotto."],
                         cost: "C'è un livello gratuito con limiti di richieste al giorno (variano nel tempo): per le ricerche di Aether basta di solito.")
        case .openrouter:
            return Guide(url: "https://openrouter.ai/keys", linkTitle: "openrouter.ai",
                         steps: ["Crea un account su openrouter.ai.", "Apri Keys ▸ Create Key.", "Copia la chiave (inizia con «sk-or-»).", "Aggiungi credito da Credits, oppure scegli un modello gratuito (nome che finisce con «:free»)."],
                         cost: "Una sola chiave dà accesso a molti modelli di fornitori diversi. L'elenco dei modelli si vede anche senza chiave.")
        case .custom:
            return Guide(url: "", linkTitle: "",
                         steps: ["Inserisci l'indirizzo base del server compatibile OpenAI, ad esempio https://tuo-server/v1.", "Se il server richiede una chiave, incollala qui sotto; altrimenti lasciala vuota."],
                         cost: "Il server deve essere raggiungibile via https da Internet: gli indirizzi della rete di casa sono bloccati.")
        }
    }

    var body: some View {
        DisclosureGroup("Come ottenere la chiave") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").font(.footnote)
                }
                if let url = URL(string: guide.url), !guide.url.isEmpty {
                    Link(guide.linkTitle, destination: url).font(.footnote.weight(.semibold))
                }
                Text(guide.cost).font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("advsearch.guide")
    }
}

/// Elenco dei modelli disponibili con il piano della chiave, con ricerca.
private struct AIModelPickerView: View {
    let models: [AIModelInfo]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var visible: [AIModelInfo] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return models }
        return models.filter { $0.id.lowercased().contains(text) || $0.name.lowercased().contains(text) }
    }

    var body: some View {
        List(visible) { model in
            Button {
                selection = model.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).foregroundStyle(Color.primary)
                        if model.name != model.id { Text(model.id).font(.caption).foregroundStyle(Color.aetherSecondary) }
                        if let note = model.note { Text(note).font(.caption2).foregroundStyle(.green) }
                    }
                    Spacer()
                    if model.id == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
        }
        .searchable(text: $query)
        .aetherPage()
        .navigationTitle("Modello")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Registro dei tempi della ricerca avanzata.
private struct SearchTimingLogView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        TimingList(log: env.searchTimings)
    }
}

private struct TimingList: View {
    @ObservedObject var log: SearchTimingLog
    @State private var copied = false

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("Nessuna ricerca registrata. Fai una ricerca avanzata (con «Registra i tempi» acceso) e torna qui.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            ForEach(log.entries) { entry in
                Section {
                    ForEach(Array(entry.phases.enumerated()), id: \.offset) { _, phase in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(phase.name).font(.footnote)
                                Spacer()
                                Text(String(format: "%.2f s", phase.seconds)).font(.footnote.monospacedDigit())
                            }
                            if let detail = phase.detail {
                                Text(detail).font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                    }
                    ForEach(entry.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("«\(entry.query)» · \(String(format: "%.1f", entry.total)) s · \(entry.results) risultati")
                        .textCase(nil)
                } footer: {
                    Text("\(entry.date.formatted(date: .abbreviated, time: .standard)) · \(entry.interpreter)")
                }
            }
        }
        .aetherPage()
        .navigationTitle("Registro dei tempi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "Copiato" : "Copia") {
                    UIPasteboard.general.string = log.text()
                    copied = true
                }
                .disabled(log.entries.isEmpty)
                Button("Svuota", role: .destructive) { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
        }
    }
}
