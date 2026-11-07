import Combine
import Foundation
import GroupActivities
import AetherCore

/// What is shared in a SharePlay session: the title (each person finds a source of their own), not the video.
struct AetherWatchActivity: GroupActivity {
    var type: String
    var metaID: String
    var videoID: String?
    var title: String

    var metadata: GroupActivityMetadata {
        var data = GroupActivityMetadata()
        data.title = title
        data.type = .watchTogether
        return data
    }
}

/// One line of the chat of a SharePlay session («Cinema insieme»).
struct WatchChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var sender: String
    var text: String
    var sentAt: Date = Date()
}

/// «Guarda insieme»: keeps play, pause and position of the players of the people in a SharePlay call aligned. Every person plays their own
/// source; the messages only say «playing / paused, here». It needs the SharePlay entitlement in the signature: where SideStore does not
/// give it, starting an activity fails and says so.
@MainActor
final class WatchTogetherService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status: String?
    @Published private(set) var chat: [WatchChatMessage] = []

    private weak var router: AppRouter?
    private weak var player: PlayerViewModel?
    private var session: GroupSession<AetherWatchActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks: [Task<Void, Never>] = []
    private var cancellables = Set<AnyCancellable>()
    private var isHost = false
    private var heartbeat: Task<Void, Never>?
    private var observing = false

    func configure(router: AppRouter) { self.router = router }

    /// Starts listening for sessions a friend starts.
    func observeSessions() {
        guard !observing else { return }
        observing = true
        Task { [weak self] in
            for await incoming in AetherWatchActivity.sessions() { self?.join(incoming, asHost: false) }
        }
    }

    func start(type: String, metaID: String, videoID: String?, title: String) async {
        let activity = AetherWatchActivity(type: type, metaID: metaID, videoID: videoID, title: title)
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            isHost = true
            do { _ = try await activity.activate() } catch {
                isHost = false
                status = "SharePlay non è disponibile: \(error.localizedDescription)"
            }
        case .activationDisabled:
            status = "Per guardare insieme serve una chiamata FaceTime o una conversazione in Messaggi con SharePlay attivo."
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    func attach(_ model: PlayerViewModel) { player = model }
    func detach(_ model: PlayerViewModel) { if player === model { player = nil } }

    private func join(_ incoming: GroupSession<AetherWatchActivity>, asHost: Bool) {
        leave()
        session = incoming
        isActive = true
        status = "Guardate insieme: \(incoming.activity.title)"
        let messenger = GroupSessionMessenger(session: incoming)
        self.messenger = messenger
        incoming.join()
        // The title opens for this person too; they pick their own source.
        router?.detail = MetaRoute(type: incoming.activity.type, id: incoming.activity.metaID, videoID: incoming.activity.videoID)
        chat = []
        tasks.append(Task { [weak self] in
            for await (message, _) in messenger.messages(of: PlaybackSyncMessage.self) { self?.player?.applyRemote(message) }
        })
        tasks.append(Task { [weak self] in
            for await (message, _) in messenger.messages(of: WatchChatMessage.self) { self?.chat.append(message) }
        })
        incoming.$state.sink { [weak self] state in
            if case .invalidated = state { self?.leave() }
        }.store(in: &cancellables)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self = self, self.isHost, let model = self.player else { continue }
                let state = model.currentSyncState()
                if state.isPlaying { self.send(isPlaying: true, position: state.position) }
            }
        }
    }

    func send(isPlaying: Bool, position: Double) {
        guard let messenger = messenger else { return }
        let message = PlaybackSyncMessage(isPlaying: isPlaying, position: position, sentAt: Date().timeIntervalSince1970)
        Task { try? await messenger.send(message) }
    }

    /// Sends a line to everyone in the call; it shows in the chat at once for the sender too.
    func sendChat(_ text: String, sender: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let messenger = messenger, !clean.isEmpty else { return }
        let message = WatchChatMessage(sender: sender, text: String(clean.prefix(400)))
        chat.append(message)
        Task { try? await messenger.send(message) }
    }

    func leave() {
        session?.leave()
        session = nil
        messenger = nil
        isActive = false
        isHost = false
        heartbeat?.cancel()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        cancellables.removeAll()
    }
}
