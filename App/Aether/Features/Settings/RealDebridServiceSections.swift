import SwiftUI
import AetherCore

/// Real-Debrid API credentials. The token is stored only in the Keychain and is never included in UI text or logs.
struct RealDebridServiceSections: View {
    @ObservedObject var credentials: ServiceCredentials
    let http: HTTPClient
    @State private var draft = ""
    @State private var status: String?
    @State private var checking = false

    private var hasKey: Bool { credentials.isConfigured(.realdebrid) }
    private static let endpoint = URL(string: "https://api.real-debrid.com/rest/1.0/user")!

    var body: some View {
        Section {
            if hasKey {
                Label("Token salvato nel Portachiavi", systemImage: "key.fill")
                    .accessibilityIdentifier("service.realdebrid.saved")
                if let status {
                    Label(status, systemImage: status.hasPrefix("Connesso") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.hasPrefix("Connesso") ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("service.realdebrid.status")
                }
                Button("Verifica connessione") { Task { await verify() } }
                    .disabled(checking)
                    .accessibilityIdentifier("service.realdebrid.verify")
                Button("Rimuovi il token", role: .destructive) {
                    credentials.remove(.realdebrid)
                    status = nil
                }
                .accessibilityIdentifier("service.realdebrid.remove")
            } else {
                SecureField("Token API di Real-Debrid", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("service.realdebrid.key")
                Button("Salva e verifica") { Task { await saveAndVerify() } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                    .accessibilityIdentifier("service.realdebrid.save")
                if let status {
                    Label(status, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("service.realdebrid.status")
                }
            }
        } header: {
            Text("Real-Debrid")
        } footer: {
            Text("Il token resta nel Portachiavi di questo iPhone. Puoi crearne uno dalla sezione API del tuo account Real-Debrid. Rimuoverlo da Aether non modifica il tuo account.")
        }

        Section {
            Link(destination: URL(string: "https://real-debrid.com")!) {
                Label("Apri Real-Debrid", systemImage: "safari")
            }
            Text("La verifica controlla l'accesso all'account tramite l'API ufficiale. Il token non viene mostrato nuovamente né scritto nei log.")
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Informazioni")
        }
    }

    private func saveAndVerify() async {
        do {
            try credentials.save(draft, for: .realdebrid)
            draft = ""
            status = nil
            await verify()
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor
    private func verify() async {
        guard let token = credentials.secret(for: .realdebrid) else {
            status = "Inserisci prima un token API."
            return
        }
        checking = true
        defer { checking = false }
        do {
            let request = HTTPRequest(
                url: Self.endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
                timeout: 15,
                maxBytes: 256 * 1024,
                purpose: .addonRequest
            )
            let response = try await http.send(request)
            if response.statusCode == 200 {
                status = "Connesso a Real-Debrid."
            } else if response.statusCode == 401 || response.statusCode == 403 {
                status = "Token rifiutato. Controlla o rigenera il token."
                credentials.remove(.realdebrid)
            } else {
                status = "Real-Debrid ha risposto con errore HTTP \(response.statusCode)."
            }
        } catch {
            status = "Impossibile verificare Real-Debrid. Controlla la connessione e riprova."
        }
    }
}
