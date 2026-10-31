import SwiftUI
import Combine
import AetherCore

/// The player's own UIKit container. SwiftUI's `fullScreenCover` kept the orientation of the screen under it for the first
/// frames, so iOS turned the status bar sideways while the player stayed laid out as a portrait page. This controller states
/// its orientation itself (sideways, or what the player allows once it runs), so the whole page is created already rotated.
final class LandscapeHostingController: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        let mask = AppDelegate.orientationMask
        return mask.isDisjoint(with: .landscape) ? .landscape : mask
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { return .landscapeRight }
    override var shouldAutorotate: Bool { return true }

    /// The player on screen now, so its own close button can take it down without depending on a SwiftUI update.
    nonisolated(unsafe) private(set) static weak var current: LandscapeHostingController?

    @MainActor
    static func dismissCurrent() {
        let controller = current
        current = nil
        controller?.dismiss(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        LandscapeHostingController.current = self
    }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
}

/// Presents the player (full screen, sideways) for a `PlayerRequest` and dismisses it when the request is cleared. Replaces
/// `fullScreenCover(item:)` for the player, both over the app and over Theater Mode.
struct LandscapePlayerCover: ViewModifier {
    @Binding var item: PlayerRequest?
    /// The main screen also shows the page that stands in for the player while a source is prepared (Theater Mode has its own).
    var showsLaunch = false
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.aetherStyle) private var style
    @Environment(\.imageLoader) private var loader

    func body(content: Content) -> some View {
        content.background(
            PlayerPresenter(item: item,
                            launch: showsLaunch ? env.router.launch : nil,
                            makeRoot: {
                                AnyView(PlayerStage(env: env)
                                    .environmentObject(env)
                                    .environmentObject(env.settings)
                                    .environmentObject(env.router)
                                    .environmentObject(env.addons)
                                    .environmentObject(env.library)
                                    .environmentObject(env.network)
                                    .environmentObject(env.downloads)
                                    .environmentObject(env.casting)
                                    .environmentObject(env.relay)
                                    .environment(\.imageLoader, loader)
                                    .environment(\.aetherStyle, style))
                            },
                            router: env.router,
                            dismissed: { item = nil })
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

/// What the player's container shows: the black launch page (logo, progress) while a source is prepared, the player under it, and the
/// launch page fading away once the picture runs.
struct PlayerStage: View {
    let env: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let request = router.player {
                PlayerView(request: request, env: env).id(request.id)
            }
            if let launch = router.launch {
                LaunchPage(launch: launch)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: router.launch?.id)
    }
}

private struct LaunchPage: View {
    @ObservedObject var launch: PlayerLaunch
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        PlaybackPreparingView(meta: launch.meta, resolution: launch.resolution) {
            if router.player != nil { router.player = nil } else { launch.cancel() }
        }
    }
}

private struct PlayerPresenter: UIViewRepresentable {
    let item: PlayerRequest?
    let launch: PlayerLaunch?
    let makeRoot: () -> AnyView
    let router: AppRouter
    let dismissed: () -> Void

    func makeCoordinator() -> Coordinator { return Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.alpha = 0
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.watch(router)
        context.coordinator.sync(item: item, launch: launch, view: view, makeRoot: makeRoot)
    }

    @MainActor
    final class Coordinator {
        private var controller: LandscapeHostingController?
        private var sessionActive = false
        private var presenting = false
        private var task: Task<Void, Never>?
        private var watching: AnyCancellable?

        /// Closing the player clears the router's request: take the page down at once, whatever SwiftUI re-evaluates.
        func watch(_ router: AppRouter) {
            guard watching == nil else { return }
            let close: (AppRouter) -> Void = { [weak self] router in
                guard router.player == nil, router.launch == nil, let self = self, let controller = self.controller else { return }
                self.controller = nil
                self.sessionActive = false
                controller.dismiss(animated: false)
            }
            // `$player` and `$launch` publish just before the value changes: look again on the next turn.
            let players = router.$player.map { _ in Void() }
            let launches = router.$launch.map { _ in Void() }
            watching = Publishers.Merge(players, launches)
                .receive(on: DispatchQueue.main)
                .sink { [weak router] in
                    guard let router = router else { return }
                    close(router)
                }
        }

        func sync(item: PlayerRequest?, launch: PlayerLaunch?, view: UIView, makeRoot: @escaping () -> AnyView) {
            guard item != nil || launch != nil else {
                task?.cancel()
                task = nil
                sessionActive = false
                presenting = false
                if let controller = controller {
                    self.controller = nil
                    controller.dismiss(animated: false)
                }
                return
            }
            // One container for the whole run: the launch page, then the player in the same place. One that is up (or on its way up) is
            // kept; one that never made it onto the screen is tried again.
            if sessionActive {
                if presenting || controller?.presentingViewController != nil { return }
                controller = nil
                sessionActive = false
            }
            sessionActive = true
            let immediate = launch != nil
            task?.cancel()
            task = Task { [weak self, weak view] in
                await self?.present(immediate: immediate, from: view, makeRoot: makeRoot)
            }
        }

        private func present(immediate: Bool, from view: UIView?, makeRoot: () -> AnyView) async {
            presenting = true
            defer { presenting = false }
            guard let base = Coordinator.owner(of: view) else {
                sessionActive = false
                return
            }
            // The player of a title opened without a launch page waits for a sheet that is still leaving; the launch page does not wait
            // for the list to be gone: it goes over it, at once.
            if !immediate {
                for _ in 0..<40 {
                    if Task.isCancelled { return }
                    if base.presentedViewController == nil && !base.isBeingPresented && !base.isBeingDismissed { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard !Task.isCancelled else { return }
            if let old = controller {
                controller = nil
                old.dismiss(animated: false)
            }
            OrientationController.set(.landscape)
            let host = LandscapeHostingController(rootView: makeRoot())
            host.modalPresentationStyle = .fullScreen
            host.view.backgroundColor = .black
            // A source tapped the instant the list opens finds the list still sliding in: iOS refuses a page presented over a page that is
            // moving. Look again every tenth of a second (up to two seconds) until it is still, and check that the page really came up.
            for _ in 0..<20 {
                if Task.isCancelled { return }
                var top: UIViewController = base
                while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
                let moving = top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil
                if !moving {
                    controller = host
                    top.present(host, animated: false)
                    if host.presentingViewController != nil { return }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            controller = nil
            sessionActive = false
        }

        private static func owner(of view: UIView?) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }
    }
}

extension View {
    /// The player over this screen, always opening sideways.
    func landscapePlayer(_ item: Binding<PlayerRequest?>, showsLaunch: Bool = false) -> some View {
        return modifier(LandscapePlayerCover(item: item, showsLaunch: showsLaunch))
    }
}
