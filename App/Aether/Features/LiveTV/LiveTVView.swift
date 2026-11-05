import SwiftUI
import AetherCore

/// What a tile in Live TV is: a channel of an M3U playlist or one an addon lists.
struct LiveChannel: Identifiable, Hashable {
    enum Origin: Hashable {
        case m3u(M3UChannel)
        case addon(MetaItem)
    }

    let id: String
    var name: String
    var logo: String?
    var group: String?
    var origin: Origin
}

/// A place channels come from.
struct LiveSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case favorites
        case playlist(UUID)
        case catalog(addonID: UUID, key: String)
    }

    let id: String
    var title: String
    var icon: String
    var kind: Kind
}

@MainActor
final class LiveTVModel: ObservableObject {
    @Published var selected: String = "favorites"
    @Published var group: String?
    @Published var query = ""
    @Published private(set) var channels: [LiveChannel] = []
    @Published private(set) var groups: [(name: String, count: Int)] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var canLoadMore = false

    private var generation = 0
    private var loadedCount = 0
    private var catalogChannels: [LiveChannel] = []

    /// All the sources in the order they are offered: favourites, playlists, then the addon catalogs the viewer chose.
    func sources(env: AppEnvironment, addons: AddonStore, settings: LiveTVSettings) -> [LiveSource] {
        var result: [LiveSource] = []
        if !settings.favorites.isEmpty { result.append(LiveSource(id: "favorites", title: "Preferiti", icon: "star.fill", kind: .favorites)) }
        for playlist in settings.playlists {
            result.append(LiveSource(id: "playlist:" + playlist.id.uuidString, title: playlist.name, icon: "list.bullet.rectangle.fill", kind: .playlist(playlist.id)))
        }
        for addon in addons.enabledAddons {
            for catalog in addon.manifest.catalogs {
                let key = addon.id.uuidString + "/" + catalog.key
                let searchOnly = catalog.supportsSearch && !catalog.isPlainFeed && DiscoverFiltering.serverFilter(for: catalog) == nil
                guard !searchOnly, settings.includes(catalogKey: key, isTVType: ContentTypes.canonicalID(catalog.type) == "tv") else { continue }
                result.append(LiveSource(id: "catalog:" + key, title: catalog.name, icon: "dot.radiowaves.left.and.right", kind: .catalog(addonID: addon.id, key: catalog.key)))
            }
        }
        return result
    }

    /// The genre options a catalog source offers as groups.
    func catalogGroups(_ source: LiveSource, addons: AddonStore) -> [String] {
        guard case .catalog(let addonID, let key) = source.kind, let addon = addons.addons.first(where: { $0.id == addonID }),
              let catalog = addon.manifest.catalogs.first(where: { $0.key == key }), let filter = DiscoverFiltering.serverFilter(for: catalog), filter.kind == .genre else { return [] }
        return filter.options
    }

    func load(_ source: LiveSource, env: AppEnvironment, addons: AddonStore, settings: LiveTVSettings, playlists: LivePlaylistService, more: Bool = false) async {
        generation += 1
        let mine = generation
        message = nil
        switch source.kind {
        case .favorites:
            catalogChannels = settings.favorites.map { favorite in
                if let url = favorite.url {
                    let channel = M3UChannel(id: favorite.id, name: favorite.name, logo: favorite.logo, group: nil, url: url, userAgent: favorite.userAgent, referrer: favorite.referrer)
                    return LiveChannel(id: favorite.id, name: favorite.name, logo: favorite.logo, group: nil, origin: .m3u(channel))
                }
                let meta = MetaItem(id: favorite.metaID ?? favorite.id, type: favorite.metaType ?? "tv", name: favorite.name, poster: favorite.logo)
                return LiveChannel(id: favorite.id, name: favorite.name, logo: favorite.logo, group: nil, origin: .addon(meta))
            }
            canLoadMore = false
            publish()
        case .playlist(let id):
            guard let playlist = settings.playlists.first(where: { $0.id == id }) else { return }
            isLoading = playlists.cached(id).isEmpty
            await playlists.load(playlist)
            guard mine == generation else { return }
            isLoading = false
            catalogChannels = playlists.cached(id).map { LiveChannel(id: "m3u:" + $0.id, name: $0.name, logo: $0.logo, group: $0.group, origin: .m3u($0)) }
            message = playlists.messages[id]
            canLoadMore = false
            publish()
        case .catalog(let addonID, let key):
            guard let addon = addons.addons.first(where: { $0.id == addonID }), let catalog = addon.manifest.catalogs.first(where: { $0.key == key }) else { return }
            let filter = DiscoverFiltering.serverFilter(for: catalog)
            var chosen = group
            if let filter = filter, filter.kind == .genre, filter.isRequired, chosen == nil || !(filter.options.contains(chosen ?? "")) { chosen = filter.options.first }
            var extra: [ExtraValue] = []
            if let chosen = chosen { extra.append(ExtraValue(name: "genre", value: chosen)) }
            if more, catalog.extraProperty("skip") != nil { extra.append(ExtraValue(name: "skip", value: String(loadedCount))) }
            if !more { loadedCount = 0; catalogChannels = [] }
            isLoading = !more
            defer { if mine == generation { isLoading = false } }
            do {
                let ref = CatalogRef(addonID: addon.id, addonName: addon.displayName, catalog: catalog)
                let result = try await env.service.catalog(ref, extra: extra)
                guard mine == generation else { return }
                loadedCount += result.rawCount
                let fresh = result.items.map { LiveChannel(id: "addon:" + $0.id, name: $0.name, logo: $0.poster, group: nil, origin: .addon($0)) }
                var known = Set(catalogChannels.map { $0.id })
                catalogChannels += fresh.filter { known.insert($0.id).inserted }
                canLoadMore = catalog.extraProperty("skip") != nil && result.rawCount > 0
                if catalogChannels.isEmpty { message = "Il catalogo non ha canali per questa scelta." }
                publish(groupsFromChannels: false)
            } catch {
                guard mine == generation else { return }
                message = "Non riesco a leggere il catalogo: \(error.localizedDescription)"
                publish(groupsFromChannels: false)
            }
        }
    }

    private func publish(groupsFromChannels: Bool = true) {
        let filtered = catalogChannels.filter { channel in
            if groupsFromChannels, let group = group, channel.group != group { return false }
            let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(separator: " ").map(String.init)
            if words.isEmpty { return true }
            let hay = (channel.name + " " + (channel.group ?? "")).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
        channels = filtered
        if groupsFromChannels {
            var order: [String] = []
            var counts: [String: Int] = [:]
            for channel in catalogChannels {
                guard let name = channel.group else { continue }
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += 1
            }
            groups = order.map { (name: $0, count: counts[$0] ?? 0) }
        } else {
            groups = []
        }
    }

    func refilter() { publish(groupsFromChannels: !(sourceIsCatalog)) }

    var sourceIsCatalog = false
}

struct LiveTVView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var playlists: LivePlaylistService
    @StateObject private var model = LiveTVModel()
    @State private var notice: String?

    private var liveSettings: LiveTVSettings { return settings.value.content.liveTV }
    private var sources: [LiveSource] { return model.sources(env: env, addons: addons, settings: liveSettings) }
    private var current: LiveSource? { return sources.first(where: { $0.id == model.selected }) ?? sources.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    searchField
                    if sources.isEmpty {
                        emptyState
                    } else {
                        sourceChips
                        groupChips
                        if let message = model.message { Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(Color.aetherSecondary).padding(.horizontal, 4) }
                        grid
                        if model.canLoadMore {
                            Button { Task { await reload(more: true) } } label: { Label("Carica altri canali", systemImage: "arrow.down.circle") }
                                .buttonStyle(SecondaryActionButtonStyle()).frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { LiveTVSettingsView() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Impostazioni di Live TV")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Aggiorna")
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = notice {
                    Text(notice).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                        .aetherGlassCapsule().padding(.bottom, 16).transition(.opacity)
                }
            }
        }
        .task(id: sources.map { $0.id }) {
            if current?.id != model.selected, let first = current { model.selected = first.id }
            await reload()
        }
        .onChange(of: model.selected) { _, _ in model.group = nil; Task { await reload() } }
        .onChange(of: model.group) { _, _ in Task { await reload(groupChange: true) } }
        .onChange(of: model.query) { _, _ in model.refilter() }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.aetherSecondary)
            TextField("Cerca un canale", text: $model.query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("live.search")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.aetherSecondary) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.thinMaterial, in: Capsule())
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    chip(source.title, icon: source.icon, on: source.id == (current?.id ?? "")) { model.selected = source.id }
                }
            }
        }
    }

    @ViewBuilder
    private var groupChips: some View {
        let catalogGroups = current.map { model.catalogGroups($0, addons: addons) } ?? []
        if !catalogGroups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(catalogGroups, id: \.self) { name in chip(name, icon: nil, on: (model.group ?? catalogGroups.first) == name, small: true) { model.group = name } }
                }
            }
        } else if model.groups.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Tutti", icon: nil, on: model.group == nil, small: true) { model.group = nil }
                    ForEach(model.groups, id: \.name) { item in chip("\(item.name) · \(item.count)", icon: nil, on: model.group == item.name, small: true) { model.group = item.name } }
                }
            }
        }
    }

    private func chip(_ title: String, icon: String?, on: Bool, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon { Image(systemName: icon).font(.system(size: small ? 11 : 13, weight: .semibold)) }
                Text(title).font(.system(size: small ? 13 : 15, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .padding(.horizontal, small ? 12 : 14).padding(.vertical, small ? 7 : 9)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? AnyShapeStyle(settings.accentColor.gradient) : AnyShapeStyle(.thinMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(model.channels) { channel in
                ChannelTile(channel: channel, isFavorite: liveSettings.isFavorite(channel.id.replacingOccurrences(of: "m3u:", with: "").replacingOccurrences(of: "addon:", with: "")),
                            onPlay: { play(channel) }, onFavorite: { toggleFavorite(channel) }, onCopy: { copy(channel) })
            }
        }
        .overlay {
            if model.isLoading { ProgressView().controlSize(.large).padding(40) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.and.hifispeaker.fill").font(.system(size: 54)).foregroundStyle(settings.accentColor.gradient)
            Text("Nessun canale ancora").font(.title3.weight(.bold))
            Text("Aggiungi una playlist M3U oppure scegli quali cataloghi dei tuoi addon sono TV in diretta.")
                .font(.subheadline).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            NavigationLink { LiveTVSettingsView() } label: { Label("Imposta Live TV", systemImage: "slider.horizontal.3") }
                .buttonStyle(PrimaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: Actions

    private func reload(force: Bool = false, more: Bool = false, groupChange: Bool = false) async {
        guard let source = current else { return }
        model.sourceIsCatalog = { if case .catalog = source.kind { return true } else { return false } }()
        if force, case .playlist(let id) = source.kind, let playlist = liveSettings.playlists.first(where: { $0.id == id }) {
            await playlists.load(playlist, force: true)
        }
        if groupChange, !model.sourceIsCatalog { model.refilter(); return }
        await model.load(source, env: env, addons: addons, settings: liveSettings, playlists: playlists, more: more)
    }

    private func favorite(for channel: LiveChannel) -> LiveFavorite {
        switch channel.origin {
        case .m3u(let item): return LiveFavorite(id: item.id, name: item.name, logo: item.logo, url: item.url, userAgent: item.userAgent, referrer: item.referrer)
        case .addon(let meta): return LiveFavorite(id: meta.id, name: meta.name, logo: meta.poster, metaType: meta.type, metaID: meta.id)
        }
    }

    private func toggleFavorite(_ channel: LiveChannel) {
        settings.value.content.liveTV.toggleFavorite(favorite(for: channel))
    }

    private func copy(_ channel: LiveChannel) {
        if case .m3u(let item) = channel.origin {
            UIPasteboard.general.string = item.url
            show("Link copiato")
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { notice = nil } }
    }

    private func play(_ channel: LiveChannel) {
        switch channel.origin {
        case .addon(let meta):
            router.detail = MetaRoute(type: meta.type, id: meta.id, preview: meta)
        case .m3u(let item):
            guard let url = URL(string: item.url) else { return }
            Task {
                if let blocked = await env.validateMediaURL(url) { show(blocked.message); return }
                let hints = StreamBehaviorHints(proxyRequestHeaders: item.requestHeaders)
                let stream = AddonStream(source: .url(item.url), name: item.name, behaviorHints: hints)
                let meta = MetaItem(id: "live:" + item.id, type: "tv", name: item.name, poster: item.logo)
                router.play(PlayerRequest(meta: meta, video: nil, source: .stream(stream), alternatives: []))
            }
        }
    }
}

/// One channel as a tile: its logo on a coloured card, the name, and the star that keeps it among the favourites.
private struct ChannelTile: View {
    let channel: LiveChannel
    let isFavorite: Bool
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onCopy: () -> Void

    private var hue: Double {
        let sum = channel.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Double(sum) / 360
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(spacing: 0) {
                ZStack {
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.42), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let logo = channel.logo, !logo.isEmpty {
                        RemoteImage(urlString: logo, width: 160, contentMode: .fit, placeholderSeed: channel.name, systemPlaceholder: "tv")
                            .padding(18)
                    } else {
                        Text(String(channel.name.prefix(2)).uppercased()).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                    }
                    VStack {
                        HStack {
                            Text("LIVE").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(Color.red, in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(height: 96)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(2).multilineTextAlignment(.leading)
                    if let group = channel.group { Text(group).font(.caption2).foregroundStyle(Color.aetherSecondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
                .padding(10)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isFavorite ? Color.yellow : Color.white.opacity(0.85))
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onFavorite) { Label(isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti", systemImage: isFavorite ? "star.slash" : "star") }
            if case .m3u = channel.origin { Button(action: onCopy) { Label("Copia il link", systemImage: "link") } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(channel.name)
    }
}
