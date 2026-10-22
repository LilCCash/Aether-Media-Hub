import SwiftUI
import AetherCore

/// The "Altro" of the app, dressed for Theater Mode: the same entries (addons, casting, settings, information) as cards, plus the
/// settings of Theater Mode itself. The pages behind them are the ones of the normal app, on the dark Theater backdrop.
struct TheaterMore: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var casting: CastCoordinator
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @AppStorage(TheaterPrefs.corners) private var corners = 1
    @State private var path: [Destination] = []

    enum Destination: Hashable { case addons, casting, settings, about, theater }

    private var accent: Color { TheaterPalette.color(palette) }
    private var radius: CGFloat { [6, 14, 20][min(max(corners, 0), 2)] }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Impostazioni").font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(.white)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        card(.addons, "puzzlepiece.extension.fill", "Addon", addons.addons.isEmpty ? "Nessuno" : "\(addons.enabledAddons.count) attivi",
                             id: "theater.more.addons")
                        card(.casting, "tv.and.mediabox.fill", "Casting", casting.statusSummary, id: "theater.more.casting")
                        card(.settings, "gearshape.fill", "Impostazioni", "Riproduzione, aspetto, servizi, dati", id: "theater.more.settings")
                        card(.theater, "sparkles.tv.fill", "Theater Mode", "Colori, locandine, introduzione", id: "theater.more.theater")
                        card(.about, "info.circle.fill", "Informazioni e licenze", "Versione e crediti", id: "theater.more.about")
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
            .background(TheaterBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Destination.self) { destination in
                Group {
                    switch destination {
                    case .addons: AddonsView()
                    case .casting: CastView()
                    case .settings: SettingsRootView()
                    case .about: AboutView()
                    case .theater: TheaterSettingsView()
                    }
                }
                .scrollContentBackground(.hidden)
                .background(TheaterBackground())
                .tint(accent)
                .preferredColorScheme(.dark)
            }
        }
    }

    private func card(_ destination: Destination, _ icon: String, _ title: String, _ detail: String, id: String) -> some View {
        Button { path.append(destination) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: radius * 0.7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(14)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(accent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}
