import SwiftUI
import AetherCore

/// Live channels converted on the phone for AVPlayer (and so for AirPlay and Picture in Picture), and which sources may be.
struct LiveConversionSettingsView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var settings: SettingsStore

    private var playback: PlaybackSettings { settings.value.playback }

    /// Addons that give live channels: those with a catalog of type «tv».
    private var liveAddons: [InstalledAddon] {
        return addons.addons.filter { addon in
            addon.isEnabled && addon.manifest.catalogs.contains { ContentTypes.canonicalID($0.type) == "tv" }
        }
    }

    var body: some View {
        Form {
            Section(footer: Text("Un canale che AVPlayer non sa aprire (di solito uno stream MPEG-TS delle playlist IPTV) viene rimesso al volo in pezzi HLS sul telefono: così va con AVPlayer, in Picture in Picture e su AirPlay. Il video H.264/HEVC e l'audio AAC/AC-3 sono copiati; l'audio MP2 o di altri formati diventa AAC; con la conversione «Completa» anche un video MPEG-2 viene ricodificato. Parte qualche secondo più tardi del normale. Se la conversione non riesce, il canale si apre con MPV.")) {
                Toggle("Converti le dirette per AVPlayer", isOn: settings.binding(\.playback.liveConversion))
                    .accessibilityIdentifier("settings.liveConversion.toggle")
            }
            if playback.liveConversion {
                Section(header: Text("Fonti da convertire"),
                        footer: Text(playback.liveConversionSources.isEmpty
                                     ? "Tutte le fonti vengono convertite. Tocca una fonte per escluderla."
                                     : "Solo le fonti segnate vengono convertite; le altre si aprono come sempre.")) {
                    sourceRow(id: ConversionSources.playlists, title: "Playlist M3U", subtitle: "I canali delle tue playlist")
                    ForEach(liveAddons) { addon in
                        sourceRow(id: addon.id.uuidString, title: addon.displayName, subtitle: "Addon")
                    }
                    if !playback.liveConversionSources.isEmpty {
                        Button("Converti tutte le fonti") { settings.value.playback.liveConversionSources = [] }
                    }
                }
            }
        }
        .aetherPage()
        .navigationTitle("Conversione delle dirette")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sourceRow(id: String, title: String, subtitle: String) -> some View {
        let list = playback.liveConversionSources
        let included = list.isEmpty || list.contains(id)
        return Button {
            toggle(id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.primary)
                    Text(subtitle).font(.caption).foregroundStyle(Color.aetherSecondary)
                }
                Spacer()
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(included ? Color.accentColor : Color.aetherSecondary)
                    .font(.title3)
            }
        }
        .accessibilityIdentifier("settings.liveConversion.source.\(id)")
    }

    /// The list starts as «everything»: the first tap leaves out the source tapped, and a list with every source in it goes back
    /// to «everything».
    private func toggle(_ id: String) {
        let everything = [ConversionSources.playlists] + liveAddons.map { $0.id.uuidString }
        var list = playback.liveConversionSources
        if list.isEmpty { list = everything }
        if let index = list.firstIndex(of: id) { list.remove(at: index) } else { list.append(id) }
        if Set(everything).isSubset(of: Set(list)) { list = [] } else if list.filter({ $0 != "-" }).isEmpty { list = ["-"] } else { list.removeAll { $0 == "-" } }
        settings.value.playback.liveConversionSources = list
    }
}
