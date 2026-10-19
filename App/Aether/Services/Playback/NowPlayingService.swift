import MediaPlayer
import UIKit

/// Lock-screen / Control Center integration: metadata, artwork and remote commands.
@MainActor
final class NowPlayingService {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
        var next: (() -> Void)?
        var previous: (() -> Void)?
    }

    private var tokens: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var info: [String: Any] = [:]

    func configure(handlers: Handlers, skipBack: Int, skipForward: Int) {
        clearCommands()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = handlers.next != nil
        center.previousTrackCommand.isEnabled = handlers.previous != nil

        add(center.playCommand) { _ in handlers.play(); return .success }
        add(center.pauseCommand) { _ in handlers.pause(); return .success }
        add(center.togglePlayPauseCommand) { _ in handlers.toggle(); return .success }
        add(center.skipForwardCommand) { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Double(skipForward)
            handlers.skip(interval); return .success
        }
        add(center.skipBackwardCommand) { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Double(skipBack)
            handlers.skip(-interval); return .success
        }
        add(center.changePlaybackPositionCommand) { event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { handlers.seek(event.positionTime) }
            return .success
        }
        if let next = handlers.next { add(center.nextTrackCommand) { _ in next(); return .success } }
        if let previous = handlers.previous { add(center.previousTrackCommand) { _ in previous(); return .success } }
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        let token = command.addTarget(handler: handler)
        tokens.append((command, token))
    }

    private func clearCommands() {
        for (command, token) in tokens { command.removeTarget(token) }
        tokens = []
    }

    func setMetadata(title: String, subtitle: String?, artworkURL: URL?, loader: ImageLoader?) {
        info = [MPMediaItemPropertyTitle: title]
        if let subtitle = subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        artworkTask?.cancel()
        guard let url = artworkURL, let loader = loader else { return }
        artworkTask = Task { [weak self] in
            guard let image = await loader.image(for: url, maxPixel: 600), !Task.isCancelled else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                self?.info[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self?.info
            }
        }
    }

    func updateProgress(position: Double, duration: Double, rate: Float, isLive: Bool) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(rate)
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkTask?.cancel()
        clearCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
