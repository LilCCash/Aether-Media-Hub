import SwiftUI
import AetherCore

/// Impostazioni ▸ Trakt: collegamento con il codice, sincronizzazione, scrobble e cataloghi.
struct TraktSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var trakt: TraktService
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    private var options: TraktSettings { settings.value.content.trakt }

    var body: some View {
        Form {
            Section {
                Toggle("Attiva Trakt", isOn: settings.binding(\.content.trakt.enabled))
                    .accessibilityIdentifier("trakt.enabled")
            } footer: {
                Text("Trakt tiene traccia di film e serie che guardi, la tua lista e i voti, anche tra app e dispositivi diversi. Serve un account gratuito su trakt.tv. Aether non vede mai la tua password: il collegamento avviene sul sito di Trakt con un codice.")
            }

            accountSection

            if options.enabled {
                Section {
                    Toggle("Segnala cosa guardo (scrobble)", isOn: settings.binding(\.content.trakt.scrobble))
                    Toggle("Lista in comune (watchlist)", isOn: settings.binding(\.content.trakt.syncWatchlist))
                    Toggle("Titoli già visti in comune", isOn: settings.binding(\.content.trakt.syncWatched))
                    Toggle("Sincronizza all'apertura dell'app", isOn: settings.binding(\.content.trakt.syncOnLaunch))
                } header: {
                    Text("Sincronizzazione")
                } footer: {
                    Text("«Segnala» dice a Trakt quando inizi, metti in pausa e finisci un titolo, che risulta così visto. La lista e i titoli visti si completano nei due sensi: quello che manca da una parte viene aggiunto, ma la sincronizzazione non cancella niente. Togliere un titolo dalla lista di Aether lo toglie anche da Trakt.")
                }

                if trakt.isConnected {
                    Section {
                        Button {
                            Task { await trakt.syncNow() }
                        } label: {
                            HStack {
                                Text("Sincronizza ora")
                                if trakt.syncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(trakt.syncing || (!options.syncWatchlist && !options.syncWatched))
                        .accessibilityIdentifier("trakt.sync")
                        if let report = trakt.lastReport {
                            Text(report).font(.footnote)
                            if let date = trakt.lastSync {
                                Text("Ultima sincronizzazione: \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                    } footer: {
                        Text("Per non appesantire una sola volta, una sincronizzazione porta da Trakt fino a circa 150 titoli nuovi per tipo: se ne hai molti, ripeti il tasto.")
                    }
                }

                Section {
                    ForEach(TraktCatalogKind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { settings.value.content.trakt.isCatalogVisible(kind) },
                            set: { settings.value.content.trakt.setCatalog(kind, visible: $0) }))
                    }
                    Toggle("Le tue liste personali", isOn: settings.binding(\.content.trakt.showLists))
                    Stepper("Titoli per catalogo: \(options.itemsPerCatalog)", value: settings.binding(\.content.trakt.itemsPerCatalog), in: 5...50, step: 5)
                } header: {
                    Text("Cataloghi nella pagina Trakt")
                } footer: {
                    Text("La pagina Trakt è nel Profilo, sotto «Collegamenti». Alcuni cataloghi (consigliati, watchlist, da riprendere, calendario, liste) richiedono l'account collegato. Nomi, trame e locandine vengono da TMDB: senza la sua chiave (Impostazioni ▸ Servizi e chiavi) i titoli compaiono senza immagine.")
                }
            }
        }
        .navigationTitle("Trakt")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.trakt")
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            switch trakt.state {
            case .disconnected:
                Button("Collega Trakt") { Task { await trakt.connect() } }
                    .accessibilityIdentifier("trakt.connect")
            case .waiting(let code, let url, let expires):
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Apri la pagina di Trakt e accedi.").font(.footnote)
                    if let address = URL(string: url) {
                        Link(url, destination: address).font(.footnote.weight(.semibold))
                    }
                    Text("2. Inserisci questo codice:").font(.footnote)
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("trakt.code")
                    HStack {
                        Button(copied ? "Copiato" : "Copia il codice") {
                            UIPasteboard.general.string = code
                            copied = true
                        }
                        Spacer()
                        Text("Scade alle \(expires.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("In attesa dell'approvazione…").font(.footnote).foregroundStyle(Color.aetherSecondary)
                    }
                }
                Button("Annulla", role: .destructive) { trakt.cancelConnect() }
            case .connected:
                Label(trakt.user.map { "Collegato come \($0.username)" } ?? "Collegato", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let user = trakt.user {
                    LabeledContent("Piano", value: user.vip ? "VIP" : "Gratuito")
                    if let limit = user.watchlistLimit { LabeledContent("Limite della watchlist", value: "\(limit) titoli") }
                    if let limit = user.listLimit { LabeledContent("Limite delle liste", value: "\(limit)") }
                }
                Button("Scollega Trakt", role: .destructive) { Task { await trakt.disconnect() } }
                    .accessibilityIdentifier("trakt.disconnect")
            }
            if let message = trakt.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
            }
        } header: {
            Text("Account")
        } footer: {
            if case .disconnected = trakt.state {
                Text("Premendo «Collega» ricevi un codice: lo inserisci sul sito di Trakt e approvi. Se non sei già dentro a Trakt dovrai accedere.")
            }
        }
    }
}
