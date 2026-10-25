import SwiftUI
import AetherCore

/// Impostazioni ▸ Servizi: the optional third-party services Aether can use with the user's own key or account.
/// Every key lives in the Keychain; none is ever shown again after saving, logged, exported or backed up.
struct ServicesSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            ProviderSelectionSection(debrid: env.debrid, credentials: env.credentials)
            TorBoxServiceSections(debrid: env.debrid, credentials: env.credentials)
            RealDebridServiceSections(credentials: env.credentials, http: env.http)
            // MARK: - Metadata services
            MetadataServicesSections()
        }
        .navigationTitle("Servizi")
        .task { await env.debrid.verifyIfNeeded() }
    }
}

/// The TorBox account: key entry, connection status, where to find the key, and what Aether does (and never does) with it.
/// Observing DebridService directly ensures the Picker and its explanatory text refresh immediately.
private struct ProviderSelectionSection: View {
    @ObservedObject var debrid: DebridService
    @ObservedObject var credentials: ServiceCredentials

    var body: some View {
        Section {
            Picker("Provider per i torrent", selection: $debrid.selectedProvider) {
                ForEach(DebridService.ProviderChoice.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            Text(debrid.selectedProvider == .torbox
                 ? "Aether userà TorBox per controllare la cache e preparare i link."
                 : "Aether userà Real-Debrid per preparare i link. Il controllo istantaneo della cache non è supportato dall'API Real-Debrid.")
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if debrid.selectedProvider == .torbox && !credentials.isConfigured(.torbox) {
                Label("Aggiungi la chiave TorBox qui sotto per usare questo provider.", systemImage: "info.circle")
                    .font(.footnote)
            } else if debrid.selectedProvider == .realdebrid && !credentials.isConfigured(.realdebrid) {
                Label("Aggiungi prima il token Real-Debrid nella sezione dedicata.", systemImage: "info.circle")
                    .font(.footnote)
            }
        } header: {
            Text("Provider debrid attivo")
        }
    }
}

private struct TorBoxServiceSections: View {
    @ObservedObject var debrid: DebridService
    @ObservedObject var credentials: ServiceCredentials
    @State private var draft = ""
    @State private var refusal: String?

    private static let siteURL = URL(string: "https://torbox.app")!

    private var hasKey: Bool { credentials.isConfigured(ServiceKind.torbox) }

    var body: some View {
        Section {
            if hasKey {
                Label("Chiave salvata nel Portachiavi", systemImage: "key.fill")
                    .accessibilityIdentifier("service.torbox.saved")
                statusRow
                Button("Verifica connessione") { Task { await debrid.verifyConnection() } }
                    .disabled(debrid.status == DebridService.ConnectionStatus.checking)
                    .accessibilityIdentifier("service.torbox.verify")
                Button("Rimuovi la chiave", role: .destructive) { remove() }
                    .accessibilityIdentifier("service.torbox.remove")
            } else {
                SecureField("Chiave API di TorBox", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: draft) { _, _ in refusal = nil }
                    .accessibilityIdentifier("service.torbox.key")
                Button("Salva") { Task { await save() } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("service.torbox.save")
                if let refusal = refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("service.torbox.status")
                }
            }
        } header: {
            Text("TorBox")
        } footer: {
            Text("La chiave resta nel Portachiavi di questo iPhone: non finisce nei backup né nei log. Rimuoverla non cancella nulla dal tuo account TorBox.")
        }

        Section {
            Text("1. Apri torbox.app e accedi al tuo account.\n2. Nelle impostazioni dell'account cerca la sezione della chiave API (il nome della voce può cambiare) e crea o copia la tua chiave.\n3. Incollala nel campo della chiave e tocca Salva.")
                .fixedSize(horizontal: false, vertical: true)
            Text("La chiave la crei tu: Aether non ne fornisce né ne condivide una, e non la scrive mai nei log.")
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: TorBoxServiceSections.siteURL) {
                Label("Apri torbox.app", systemImage: "safari")
            }
            .accessibilityIdentifier("service.torbox.site")
        } header: {
            Text("Dove trovare la chiave")
        }

        Section {
            Text("Aether usa la chiave solo per controllare se un torrent è già in cache su TorBox e per avviare e scaricare i tuoi elementi quando lo chiedi tu. Non cancella e non ripara mai nulla nel tuo account in automatico.")
                .fixedSize(horizontal: false, vertical: true)
            Text("«In cache» significa che TorBox ha già quel torrent: il link per guardarlo arriva subito. Se non è in cache, TorBox deve prima scaricarlo e Aether ti chiede conferma.")
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("TorBox è un servizio di terzi a pagamento: usa il tuo account e solo contenuti di cui hai i diritti. Aether non è affiliato a TorBox.")
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Cosa fa Aether con la chiave")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch debrid.status {
        case .notConfigured:
            EmptyView()
        case .unverified:
            Label("Non ancora verificata in questa sessione.", systemImage: "questionmark.circle")
                .foregroundStyle(Color.aetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("service.torbox.status")
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Verifica in corso…")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("service.torbox.status")
        case .connected(let account):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connesso a TorBox · piano \(account.planName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if let expiry = account.expiresAt {
                    Text("Scade il \(expiry.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(Color.aetherSecondary)
                }
                if let notice = account.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Color.aetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("service.torbox.status")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("service.torbox.status")
        }
    }

    private func save() async {
        let value = draft
        do {
            try credentials.save(value, for: ServiceKind.torbox)
        } catch {
            refusal = error.localizedDescription
            return
        }
        draft = ""
        refusal = nil
        let failure = await debrid.verifyConnection()
        if failure == DebridError.authFailed {
            // A key TorBox refuses is useless: it is not kept, and the field comes back for another try.
            debrid.forget()
            refusal = DebridErrorText.connectionMessage(for: DebridError.authFailed) + " La chiave non è stata salvata."
        }
    }

    private func remove() {
        debrid.forget()
        refusal = nil
    }
}
