import SwiftUI
import AetherCore

/// «Audio e sottotitoli» while a video plays on a television.
///
/// - Google Cast: the receiver lists the tracks of the video and the subtitles the phone sent with it; a choice switches at once,
///   without loading the video again.
/// - DLNA (and Google Cast when the receiver reports nothing): the phone sends the video again from the same point with the chosen
///   subtitle, or, for an MKV it converts, with the chosen audio track.
struct CastTrackControls: View {
    @ObservedObject var model: PlayerViewModel
    /// Sends the video again with the choices now in the player (`performCast` of the player).
    let onRecast: () -> Void
    /// Plain rows for a `List` section, or menus for the casting overlay.
    var style: Style = .list

    enum Style { case list, menus }

    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        if let session = casting.session {
            let live = casting.canSwitchTracksLive ? session.status.tracks : nil
            let remuxAudio = convertedAudioTracks(for: session.device.target, live: live)
            let sendable = sendableSubtitles(for: session.device.target, live: live)
            if live != nil || !remuxAudio.isEmpty || !sendable.isEmpty {
                content(live: live, remuxAudio: remuxAudio, sendable: sendable)
            }
        }
    }

    @ViewBuilder
    private func content(live: CastTrackList?, remuxAudio: [EngineTrack], sendable: [SubtitleOption]) -> some View {
        // Audio: the receiver's tracks when it has more than one, otherwise the tracks of an MKV the phone converts.
        if let live = live, live.audio.count > 1 {
            picker("Audio", icon: "speaker.wave.2", selection: Binding(
                get: { live.activeAudio?.id },
                set: { id in if let id = id { casting.setTracks(audio: id, text: casting.session?.status.tracks?.activeText?.id) } }),
                   options: live.audio.map { ($0.id, $0.title) }, offLabel: nil, identifier: "cast.tracks.audio")
        } else if !remuxAudio.isEmpty {
            picker("Audio", icon: "speaker.wave.2", selection: Binding(
                get: { remuxAudio.first(where: { $0.isSelected })?.id },
                set: { id in
                    guard let id = id, let track = remuxAudio.first(where: { $0.id == id }) else { return }
                    model.selectAudioForCasting(track)
                    onRecast()
                }), options: remuxAudio.map { ($0.id, $0.title) }, offLabel: nil, identifier: "cast.tracks.audio")
        }
        // Subtitles.
        if let live = live, !live.text.isEmpty {
            picker("Sottotitoli", icon: "captions.bubble", selection: Binding(
                get: { live.activeText?.id },
                set: { id in casting.setTracks(audio: nil, text: id) }),
                   options: live.text.map { ($0.id, $0.title) }, offLabel: "Disattivati", identifier: "cast.tracks.subtitles")
        } else if !sendable.isEmpty {
            picker("Sottotitoli", icon: "captions.bubble", selection: Binding(
                get: { sendable.contains(where: { $0.id == model.selectedSubtitleID }) ? model.selectedSubtitleID : nil },
                set: { id in
                    if let id = id, let option = sendable.first(where: { $0.id == id }) { model.selectSubtitle(option) } else { model.disableSubtitles() }
                    onRecast()
                }), options: sendable.map { ($0.id, $0.title + ($0.detail.map { " · \($0)" } ?? "")) }, offLabel: "Disattivati",
                   identifier: "cast.tracks.subtitles")
        }
        Text(footnote(live: live, remuxAudio: remuxAudio))
            .font(.caption)
            .foregroundStyle(style == .menus ? Color.white.opacity(0.7) : Color.aetherSecondary)
    }

    @ViewBuilder
    private func picker<ID: Hashable>(_ title: String, icon: String, selection: Binding<ID?>, options: [(ID, String)], offLabel: String?,
                                      identifier: String) -> some View {
        let picker = Picker(selection: selection) {
            if let off = offLabel { Text(off).tag(ID?.none) }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.1).tag(ID?.some(option.0))
            }
        } label: {
            Label(title, systemImage: icon)
        }
        .accessibilityIdentifier(identifier)
        switch style {
        case .list: picker
        case .menus: picker.pickerStyle(.menu).tint(.white)
        }
    }

    private func footnote(live: CastTrackList?, remuxAudio: [EngineTrack]) -> String {
        var lines: [String] = []
        if live != nil { lines.append("Il cambio è immediato sul televisore.") }
        else { lines.append("Il televisore riceve di nuovo il video dal punto in cui è: ci vuole qualche secondo.") }
        // The file has more audio tracks than the receiver exposes: say why they are not here, instead of hiding them silently.
        if remuxAudio.isEmpty, model.audioTracks.count > 1, (live?.audio.count ?? 0) <= 1 {
            lines.append("Il file ha \(model.audioTracks.count) tracce audio, ma il televisore ne riceve una sola: "
                         + "con questo formato non si può cambiare dal telefono.")
        }
        return lines.joined(separator: " ")
    }

    /// The audio tracks of an MKV the phone converts for the receiver (one audio track is copied: changing it restarts the stream).
    private func convertedAudioTracks(for target: CastTarget, live: CastTrackList?) -> [EngineTrack] {
        guard model.audioTracks.count > 1, (live?.audio.count ?? 0) <= 1, convertsMatroska(for: target) else { return [] }
        return model.audioTracks
    }

    /// Subtitles the phone can send again with the video: files (addons, OpenSubtitles, downloads) always, embedded text tracks of an
    /// MKV it converts.
    private func sendableSubtitles(for target: CastTarget, live: CastTrackList?) -> [SubtitleOption] {
        guard target != .airPlay, live == nil || live?.text.isEmpty == true else { return [] }
        let converts = convertsMatroska(for: target)
        return model.subtitleOptions.filter { !$0.isEmbedded || converts }
    }

    private func convertsMatroska(for target: CastTarget) -> Bool {
        guard model.currentStreamInfo?.container?.lowercased() == "mkv", RemuxEngineFactory.isAvailable else { return false }
        return target == .dlna || (target == .googleCast && settings.value.casting.convertMatroskaForGoogleCast)
    }
}
