import SwiftUI
import UIKit
import AetherCore

/// A person of the cast, with the photo when TMDB has one.
struct PauseCastMember: Identifiable, Hashable {
    var id: String { return name + "|" + (role ?? "") }
    var name: String
    var role: String?
    var photo: String?
}

/// What the pause page shows besides the title: the logo and the cast. Loaded once, in the background, while the video plays.
@MainActor
final class PauseInfoModel: ObservableObject {
    @Published private(set) var logo: UIImage?
    @Published private(set) var cast: [PauseCastMember] = []
    private var loaded = false

    func load(meta: MetaItem, env: AppEnvironment) async {
        guard !loaded else { return }
        loaded = true
        logo = await FanartLogoStore.shared.load(meta: meta, env: env)
        var found: [PauseCastMember] = []
        if await env.metadata.tmdbConfigured {
            let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
            if let rich = await env.metadata.richDetails(for: meta, language: language) {
                found = rich.cast.map { PauseCastMember(name: $0.name, role: $0.role, photo: $0.photoURL) }
            }
        }
        if found.isEmpty {
            found = meta.cast.map { name in PauseCastMember(name: name, role: nil, photo: nil) }
        }
        cast = found
    }
}

/// The page that appears after a few seconds of pause: the logo (or the title in big letters) at the top left, the plot below it, the cast
/// on the right. A tap on the plot or on the cast opens it in full in a panel; a tap anywhere else (the space between them) brings the
/// player's buttons back.
struct PauseScreen: View {
    @ObservedObject var model: PlayerViewModel
    @ObservedObject var info: PauseInfoModel
    let accent: Color
    let onBringBackControls: () -> Void

    private enum Panel { case synopsis, cast }
    @State private var panel: Panel?

    private var synopsis: String {
        let episode = model.currentVideo?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !episode.isEmpty { return episode }
        return model.meta.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Everything not claimed by the plot or the cast: a tap brings the buttons back (or closes the open panel).
                Color.black.opacity(0.62).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if panel != nil { panel = nil } else { onBringBackControls() } }
                    .accessibilityIdentifier("pause.background")
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        header(maxHeight: proxy.size.height * 0.3)
                        Spacer(minLength: 0)
                        if !synopsis.isEmpty { synopsisCard }
                    }
                    .frame(width: proxy.size.width * 0.5, alignment: .leading)
                    Spacer(minLength: 0)
                    if !info.cast.isEmpty { castArea.frame(width: proxy.size.width * 0.3) }
                }
                .padding(.horizontal, max(proxy.safeAreaInsets.leading, 24) + 12)
                .padding(.vertical, 28)
                if let panel = panel {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { self.panel = nil }
                    Group {
                        switch panel {
                        case .synopsis: synopsisPanel(size: proxy.size)
                        case .cast: castPanel(size: proxy.size)
                        }
                    }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: panel)
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("player.pauseScreen")
    }

    // MARK: Pieces

    private func header(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let logo = info.logo {
                Image(uiImage: logo).resizable().scaledToFit().frame(maxHeight: max(70, maxHeight), alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            } else {
                Text(model.title).font(.system(size: 38, weight: .heavy, design: .rounded)).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
            if let line = model.episodeSubtitle(), !line.isEmpty {
                Text(line).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var synopsisCard: some View {
        Button { panel = .synopsis } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(synopsis).font(.system(size: 15, design: .rounded)).lineLimit(4).multilineTextAlignment(.leading)
                Text("Leggi tutto").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pause.synopsis")
    }

    private var castArea: some View {
        Button { panel = .cast } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cast").font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(info.cast.prefix(6)) { member in bubble(member, size: 64) }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pause.cast")
    }

    private func bubble(_ member: PauseCastMember, size: CGFloat) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.white.opacity(0.14))
                if let photo = member.photo, !photo.isEmpty {
                    RemoteImage(urlString: photo, width: size * 2, contentMode: .fill, placeholderSeed: member.name, systemPlaceholder: "person.fill")
                        .frame(width: size, height: size).clipShape(Circle())
                } else {
                    Text(String(member.name.prefix(1))).font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                }
            }
            .frame(width: size, height: size)
            Text(member.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(2).multilineTextAlignment(.center)
            if let role = member.role, !role.isEmpty {
                Text(role).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func synopsisPanel(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.system(size: 20, weight: .heavy, design: .rounded))
            if let line = model.episodeSubtitle(), !line.isEmpty { Text(line).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75)) }
            ScrollView { Text(synopsis).font(.system(size: 17, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(22)
        .frame(width: min(size.width * 0.72, 720), height: size.height * 0.78, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {}
        .accessibilityIdentifier("pause.synopsis.panel")
    }

    private func castPanel(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.system(size: 20, weight: .heavy, design: .rounded))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 16) {
                    ForEach(info.cast) { member in bubble(member, size: 76) }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
        .frame(width: min(size.width * 0.8, 820), height: size.height * 0.82, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {}
        .accessibilityIdentifier("pause.cast.panel")
    }
}
