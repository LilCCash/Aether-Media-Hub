import SwiftUI
import AetherCore

// The pieces of the glass Home (Impostazioni ▸ Aspetto ▸ Personalizza la Home ▸ Vetrina): a header with the name and the
// profile picture, a search field, the categories. The rows below are the ones of the classic Home.

/// «Aether» on the left; the cast button and the profile picture on the right; a greeting under them.
struct GlassHomeHeader: View {
    let glass: GlassHomeSettings
    let onCast: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.m) {
                if glass.showLogo {
                    Text("Aether")
                        .font(.aetherTitle(26))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                GlassCircleButton(systemName: "tv.and.mediabox", label: "Trasmetti su un dispositivo", action: onCast)
                    .accessibilityIdentifier("home.cast")
                if glass.showAvatar {
                    Button {
                        Haptics.tap()
                        router.profileSheet = true
                    } label: {
                        AvatarView(avatarID: settings.value.content.profile.avatar, size: 40)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.2))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Profilo")
                    .accessibilityIdentifier("home.profile")
                }
            }
            if glass.showGreeting {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(greeting)
                        .font(.aetherTitle(40))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Cosa vuoi guardare oggi?")
                        .font(.system(.title3, design: AetherTypography.design).weight(.medium))
                        .foregroundStyle(Color.aetherSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.greeting")
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.top, Space.s)
        .repaintsWithTitleFont()
    }

    private var greeting: String {
        let name = Greeting.sanitizedName(settings.value.appearance.greetingName)
        return name.isEmpty ? "Ciao!" : "Ciao, \(name)!"
    }
}

/// A round glass button of the header, 44 pt.
struct GlassCircleButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .aetherGlass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}

/// The picture of the featured title, soft and faded, behind the top of the page: the Home takes its colours, as in the mock-up.
struct GlassHomeAtmosphere: View {
    let item: MetaItem?
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let item = item, !settings.reduceEffects, let picture = item.background ?? item.poster {
            RemoteImage(urlString: picture, width: 900, contentMode: .fill, placeholderSeed: item.name)
                .frame(height: 520)
                .frame(maxWidth: .infinity)
                .clipped()
                .blur(radius: 26)
                .opacity(scheme == .dark ? 0.55 : 0.45)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.8), location: 0.45),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The search field of the Home: a tap opens Cerca, with its engine and filters.
struct GlassSearchField: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold))
                Text("Cerca film, serie, canali…").font(.body)
                    .foregroundStyle(Color.aetherSecondary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.xl)
            .frame(height: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .aetherGlassCapsule(interactive: true)
        .overlay(Sheen(shape: Capsule()))
        .padding(.horizontal, Theme.pageMargin)
        .accessibilityLabel("Cerca")
        .accessibilityHint("Apre la ricerca")
        .accessibilityIdentifier("home.search")
    }
}

/// The categories: glass tiles with a symbol and a name, four to a row.
struct GlassCategoryGrid: View {
    let categories: [HomeCategory]
    let open: (HomeCategory) -> Void

    var body: some View {
        if !categories.isEmpty {
            let columns = Array(repeating: GridItem(.flexible(), spacing: Space.m), count: min(4, max(1, categories.count)))
            LazyVGrid(columns: columns, spacing: Space.m) {
                ForEach(categories) { category in
                    GlassCategoryTile(category: category) { open(category) }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .accessibilityIdentifier("home.categories")
        }
    }
}

struct GlassCategoryTile: View {
    let category: HomeCategory
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                Image(systemName: category.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 30)
                Text(category.title)
                    .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .contentShape(RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous))
        }
        .buttonStyle(.pressable)
        .aetherGlass(in: RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous), interactive: true)
        .overlay(Sheen(shape: RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous)))
        .accessibilityLabel(category.title)
        .accessibilityIdentifier("home.category.\(category.id)")
    }
}
