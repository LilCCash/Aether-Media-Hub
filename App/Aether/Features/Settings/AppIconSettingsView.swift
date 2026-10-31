import SwiftUI

/// One icon the viewer can choose: the app's own (which follows the system theme on iOS 18) or one of the alternates in the asset catalog.
struct AppIconChoice: Identifiable {
    /// The name of the alternate icon set; empty for the main icon.
    let id: String
    let title: String
    let detail: String
    /// The name of the preview image in the asset catalog.
    let preview: String

    var alternateName: String? { return id.isEmpty ? nil : id }
}

struct AppIconSettingsView: View {
    private static let choices: [AppIconChoice] = [
        AppIconChoice(id: "", title: "Automatica", detail: "Segue il tema del sistema (chiara, scura, tinta su iOS 18)", preview: "IconPreviewLight"),
        AppIconChoice(id: "AppIconLight", title: "Chiara", detail: "Sempre chiara", preview: "IconPreviewLight"),
        AppIconChoice(id: "AppIconDark", title: "Scura", detail: "Sempre scura", preview: "IconPreviewDark"),
        AppIconChoice(id: "AppIconCinema", title: "Cinema", detail: "Pellicola, rosso velluto e oro", preview: "IconPreviewCinema"),
        AppIconChoice(id: "AppIconHalloween", title: "Halloween", detail: "Viola, arancio, luna e pipistrelli", preview: "IconPreviewHalloween"),
        AppIconChoice(id: "AppIconNatale", title: "Natale", detail: "Verde, rosso e fiocchi di neve", preview: "IconPreviewNatale"),
        AppIconChoice(id: "AppIconWestern", title: "Western", detail: "Sabbia, sceriffo e dune", preview: "IconPreviewWestern"),
        AppIconChoice(id: "AppIconSciFi", title: "Fantascienza", detail: "Spazio, neon e pianeti", preview: "IconPreviewSciFi"),
        AppIconChoice(id: "AppIconGiallo", title: "Giallo poliziesco", detail: "Giallo, nero e nastro della scientifica", preview: "IconPreviewGiallo"),
    ]

    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var problem: String?

    private var currentPreview: String {
        return AppIconSettingsView.choices.first { $0.alternateName == current }?.preview ?? "IconPreviewLight"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Image(currentPreview)
                        .resizable()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                        .accessibilityHidden(true)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            }
            Section(footer: Text("Cambiano solo i colori e le decorazioni: il disegno resta lo stesso. Quando cambi icona, iOS mostra un avviso.")) {
                ForEach(AppIconSettingsView.choices) { choice in
                    Button { select(choice) } label: {
                        HStack(spacing: 14) {
                            Image(choice.preview)
                                .resizable()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).foregroundStyle(.primary)
                                Text(choice.detail).font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                            Spacer()
                            if current == choice.alternateName {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityAddTraits(current == choice.alternateName ? .isSelected : [])
                }
            }
        }
        .navigationTitle("Icona dell'app")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Non riesco a cambiare l'icona", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func select(_ choice: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else {
            problem = "Questo dispositivo non permette di cambiare l'icona."
            return
        }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            DispatchQueue.main.async {
                if let error = error { problem = error.localizedDescription } else { current = choice.alternateName }
            }
        }
    }
}
