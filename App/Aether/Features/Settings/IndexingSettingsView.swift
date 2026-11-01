import SwiftUI
import AetherCore

/// Esegue «Indicizza ora» e tiene i progressi anche se esci dalla pagina.
@MainActor
final class IndexingRunModel: ObservableObject {
    @Published private(set) var progress: SpotlightIndexer.IndexProgress?
    @Published private(set) var running = false
    private var task: Task<Void, Never>?

    func start(service: AddonService) {
        guard !running else { return }
        running = true
        progress = .collecting(done: 0, target: 0)
        task = Task { [weak self] in
            await SpotlightIndexer.indexNow(service: service) { [weak self] value in self?.progress = value }
            self?.running = false
        }
    }

    func cancel() { task?.cancel() }
}

/// Impostazioni ▸ Indicizzazione: quanti titoli e locandine mettere nella ricerca di iPhone (Spotlight).
struct IndexingSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var run = IndexingRunModel()
    @State private var titles = 0
    @State private var posters = 0
    @State private var bytes: Int64 = 0
    @State private var confirmClear = false

    private var options: IndexingSettings { settings.value.content.indexing }

    var body: some View {
        Form {
            Section {
                Picker("Titoli da indicizzare", selection: settings.binding(\.content.indexing.limit)) {
                    ForEach(choices, id: \.self) { Text("\($0)").tag($0) }
                }
                .accessibilityIdentifier("indexing.limit")
                Toggle("Indicizza anche le locandine", isOn: settings.binding(\.content.indexing.includePosters))
                Toggle("Raccogli titoli dai miei cataloghi", isOn: settings.binding(\.content.indexing.fillFromCatalogs))
                Toggle("Aggiorna da solo mentre uso l'app", isOn: settings.binding(\.content.indexing.automatic))
            } header: {
                Text("Quanti titoli")
            } footer: {
                Text("Spotlight trova film e serie di Aether dalla schermata Home e dalla ricerca di iPhone. Il numero comprende la tua libreria (lista e preferiti), poi i titoli visti di recente. Ogni locandina pesa circa 10-20 KB: con 5000 titoli sono circa 50-100 MB, nella cache dell'app. Con «Raccogli titoli dai miei cataloghi» il tasto «Indicizza ora» scorre i cataloghi dei tuoi addon per arrivare al numero scelto; senza, indicizza solo i titoli che l'app conosce già.")
            }

            Section {
                LabeledContent("Titoli pronti da indicizzare", value: "\(titles)")
                LabeledContent("Locandine salvate", value: "\(posters) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            } header: {
                Text("Stato")
            } footer: {
                Text("I titoli restano indicizzati anche chiudendo l'app. L'indice viene rifatto quando premi «Indicizza ora» e, se è acceso, anche da solo mentre usi l'app. Se reinstalli l'app, iOS può toglierli: basta premere di nuovo il tasto.")
            }

            Section {
                Button {
                    run.start(service: env.service)
                } label: {
                    Text("Indicizza ora")
                }
                .disabled(run.running)
                .accessibilityIdentifier("indexing.start")
                if let progress = run.progress { progressView(progress) }
                if run.running {
                    Button("Interrompi", role: .destructive) { run.cancel() }
                }
            } footer: {
                Text("Puoi lasciare la pagina mentre lavora: l'indicizzazione continua finché l'app resta aperta.")
            }

            Section {
                Button("Togli i titoli da Spotlight e cancella le locandine", role: .destructive) { confirmClear = true }
                    .disabled(run.running)
                    .accessibilityIdentifier("indexing.clear")
            }
        }
        .navigationTitle("Indicizzazione")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onChange(of: run.progress) { _, _ in refresh() }
        .onChange(of: settings.value.content.indexing.limit) { _, _ in refresh() }
        .confirmationDialog("Togliere i titoli di Aether da Spotlight?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Togli e cancella", role: .destructive) {
                Task {
                    await SpotlightIndexer.clearAll()
                    refresh()
                }
            }
        } message: {
            Text("Potrai reinserirli con «Indicizza ora».")
        }
    }

    /// Le scelte standard, più il valore attuale se è diverso.
    private var choices: [Int] {
        let current = options.limit
        return IndexingSettings.choices.contains(current) ? IndexingSettings.choices : (IndexingSettings.choices + [current]).sorted()
    }

    private func refresh() {
        titles = SpotlightIndexer.knownTitleCount
        posters = SpotlightIndexer.posterCount()
        bytes = SpotlightIndexer.posterBytes()
    }

    @ViewBuilder
    private func progressView(_ progress: SpotlightIndexer.IndexProgress) -> some View {
        switch progress {
        case .collecting(let done, let target):
            VStack(alignment: .leading, spacing: 6) {
                Text(target > 0 ? "Raccolgo i titoli: \(done) di \(target)" : "Preparo…").font(.footnote)
                ProgressView(value: Double(done), total: Double(max(target, 1)))
            }
        case .indexing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Scrivo l'indice di Spotlight…").font(.footnote)
            }
        case .posters(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                Text(total > 0 ? "Scarico le locandine: \(done) di \(total)" : "Tutte le locandine sono già salvate.").font(.footnote)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
            }
        case .finished(let count, let images):
            Label("Fatto: \(count) titoli indicizzati, \(images) locandine salvate.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .cancelled:
            Label("Interrotto.", systemImage: "xmark.circle").font(.footnote).foregroundStyle(Color.aetherSecondary)
        }
    }
}
