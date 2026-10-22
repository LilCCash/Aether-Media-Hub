import SwiftUI
import AetherCore

/// Impostazioni ▸ Servizi: le chiavi facoltative di TMDB e TheTVDB. Ogni servizio ha la sua sezione; la chiave è
/// dell'utente, vive nel Portachiavi e non compare mai nei log, nei backup o nell'interfaccia.
struct MetadataServicesSections: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        MetadataKeySection(kind: .tmdb, credentials: env.credentials)
        MetadataKeySection(kind: .tvdb, credentials: env.credentials)
    }
}

private struct MetadataKeySection: View {
    let kind: ServiceKind
    @ObservedObject var credentials: ServiceCredentials
    @EnvironmentObject private var env: AppEnvironment
    @State private var draft = ""
    @State private var pinDraft = ""
    @State private var check: CheckState = .idle

    private enum CheckState: Equatable {
        case idle, running, accepted
        case rejected(String)
    }

    private var identifier: String { "service.\(kind.rawValue)" }

    var body: some View {
        Section {
            if credentials.isConfigured(kind) {
                Label("Chiave salvata nel Portachiavi", systemImage: "key.fill")
                    .accessibilityIdentifier("\(identifier).saved")
                Button("Verifica la chiave") { Task { await verify(afterSave: false) } }
                    .disabled(check == .running)
                    .accessibilityIdentifier("\(identifier).verify")
                Button("Rimuovi la chiave", role: .destructive) { remove() }
                    .accessibilityIdentifier("\(identifier).remove")
            } else {
                SecureField(keyPlaceholder, text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("\(identifier).key")
                if kind == .tvdb {
                    SecureField("PIN dell'abbonamento (solo se la chiave lo richiede)", text: $pinDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("\(identifier).pin")
                }
                Button("Salva e verifica") { Task { await save() } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || check == .running)
                    .accessibilityIdentifier("\(identifier).save")
            }
            statusRow
        } header: {
            Text(kind.title)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch check {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Verifica in corso…")
            }
            .accessibilityIdentifier("\(identifier).status")
        case .accepted:
            Label("Il servizio accetta la chiave.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifier).status")
        case .rejected(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifier).status")
        }
    }

    private var keyPlaceholder: String {
        switch kind {
        case .tmdb: return "Token di lettura API (v4) o chiave API (v3)"
        default: return "Chiave API"
        }
    }

    private var footer: String {
        let privacy = "La chiave resta nel Portachiavi di questo iPhone (mai nei backup né nei log). Senza chiave l'app funziona come prima: i dati dell'addon non vengono mai sostituiti, solo completati dove mancano."
        switch kind {
        case .tmdb:
            return "Aggiunge locandina, sfondo, logo, trama, cast e titoli degli episodi quando l'addon non li fornisce. Crea un account gratuito su themoviedb.org e copia il «Token di lettura API» da Impostazioni ▸ API. \(privacy)\n\n\(MetadataService.tmdb.attribution)"
        default:
            return "Completa i titoli e le trame degli episodi che né l'addon né TMDB conoscono. Registra un progetto su thetvdb.com e copia la chiave; se è una chiave «user-supported» serve anche il PIN del tuo abbonamento. Rispetta le condizioni d'uso di TheTVDB per la tua chiave. \(privacy)\n\n\(MetadataService.tvdb.attribution)"
        }
    }

    private func save() async {
        do {
            try credentials.save(draft, for: kind, pin: kind == .tvdb ? pinDraft : nil)
        } catch {
            check = .rejected(error.localizedDescription)
            return
        }
        draft = ""
        pinDraft = ""
        await verify(afterSave: true)
    }

    private func remove() {
        credentials.remove(kind)
        check = .idle
    }

    private func verify(afterSave: Bool) async {
        check = .running
        let result = kind == .tmdb ? await env.metadata.checkTMDB() : await env.metadata.checkTVDB()
        switch result {
        case .ok:
            check = .accepted
        case .failed(let error):
            if afterSave && error == .invalidCredentials {
                // A key the service refuses is useless: do not keep it.
                credentials.remove(kind)
                check = .rejected("\(error.message) La chiave non è stata salvata.")
            } else if afterSave {
                check = .rejected("Chiave salvata, ma non è stato possibile verificarla. \(error.message)")
            } else {
                check = .rejected(error.message)
            }
        }
    }
}
