import SwiftUI
import AetherCore

/// The poster the viewer chose for a title instead of the addon's one; kept on the phone and used wherever the title's poster is shown.
@MainActor
final class PosterOverrides: ObservableObject {
    static let shared = PosterOverrides()
    private static let key = "aether.posterOverrides.v1"
    @Published private(set) var urls: [String: String]

    private init() {
        urls = (UserDefaults.standard.dictionary(forKey: PosterOverrides.key) as? [String: String]) ?? [:]
    }

    func url(for id: String) -> String? {
        return urls[id]
    }

    /// `nil` puts the original poster back.
    func set(_ url: String?, for id: String) {
        urls[id] = url
        UserDefaults.standard.set(urls, forKey: PosterOverrides.key)
    }
}

/// The list of alternative posters TMDB has for a title, with the way back to the original.
struct PosterPickerSheet: View {
    let meta: MetaItem
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var overrides = PosterOverrides.shared
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [String] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(40)
                } else if urls.isEmpty {
                    Text("TMDB non ha altre locandine per questo titolo, oppure manca la chiave TMDB (Impostazioni ▸ Servizi).")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(urls, id: \.self) { url in
                            Button {
                                overrides.set(url, for: meta.id)
                                dismiss()
                            } label: {
                                RemoteImage(urlString: url, width: 100, placeholderSeed: meta.name)
                                    .frame(width: 100, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.accentColor, lineWidth: overrides.url(for: meta.id) == url ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Locandine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Originale") {
                        overrides.set(nil, for: meta.id)
                        dismiss()
                    }
                    .disabled(overrides.url(for: meta.id) == nil)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } }
            }
            .task {
                let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
                urls = await env.metadata.posterAlternatives(for: meta, language: language)
                loading = false
            }
        }
    }
}
