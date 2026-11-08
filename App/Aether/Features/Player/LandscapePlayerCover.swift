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
        controller?.dismissThenTurnBack()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        LandscapeHostingController.current = self
    }

    /// True while a player page (or the black launch page) is on screen anywhere in the presented chain.
    @MainActor
    static var isShowing: Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return false }
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            if current is LandscapeHostingController { return true }
            controller = current.presentedViewController
        }
        return false
    }

    /// The player page that is topmost in the presented chain, taken down whatever the coordinator remembers.
    @MainActor
    static func dismissTopmost() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var controller = scene.keyWindow?.rootViewController
        var found: LandscapeHostingController?
        while let current = controller {
            if let page = current as? LandscapeHostingController { found = page }
            controller = current.presentedViewController
        }
        found?.dismissThenTurnBack()
    }

    /// A dismissal asked while the page was still moving (typical when an error shows the instant it opens) is silently ignored by
    /// iOS, and the close button then seemed dead until a later tap. This asks again until the page is really gone.
    @MainActor
    static func closeUntilGone(_ router: AppRouter) {
        Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard router.player == nil, isShowing else { return }
                router.launch = nil
                dismissTopmost()
            }
        }
    }

    /// Takes the page down and only then gives the screen back to the orientation of the app: asked before, the request is refused
    /// (this page, still on top, only allows landscape) and the app stays sideways. Asked once more a moment later, for the slow cases.
    @MainActor
    func dismissThenTurnBack() {
        dismiss(animated: false) {
            OrientationController.restore()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                OrientationController.restore()
            }
        }
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
    // Observed on purpose: the page must appear the moment the router gets a launch, not at the next unrelated redraw of this screen.
    @EnvironmentObject private var router: AppRouter
    @Environment(\.aetherStyle) private var style
    @Environment(\.imageLoader) private var loader

    func body(content: Content) -> some View {
        content.background(
            PlayerPresenter(item: item,
                            launch: showsLaunch ? router.launch : nil,
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
        PlaybackIntroView(meta: launch.meta, intro: launch.intro, resolution: launch.resolution, ready: launch.ready && router.player == nil,
                          starting: router.player != nil,
                          arrived: launch.arrivesFromPicker,
                          watch: {
                              guard let request = launch.pending else { return }
                              launch.pending = nil
                              launch.ready = false
                              router.play(request)
                          },
                          cancel: {
                              if router.player != nil { router.player = nil } else { launch.cancel() }
                          })
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
        private weak var router: AppRouter?
        private var task: Task<Void, Never>?
        private var watching: AnyCancellable?
        /// Watches the page once it is up: iOS can take it down with a page under it (a list that leaves while the screen turns).
        private var watchdog: Task<Void, Never>?
        private var revivals = 0

        /// Closing the player clears the router's request: take the page down at once, whatever SwiftUI re-evaluates.
        func watch(_ router: AppRouter) {
            self.router = router
            guard watching == nil else { return }
            let close: (AppRouter) -> Void = { [weak self] router in
                guard router.player == nil, router.launch == nil, let self = self, let controller = self.controller else { return }
                self.watchdog?.cancel()
                self.watchdog = nil
                self.revivals = 0
                self.controller = nil
                self.sessionActive = false
                controller.dismissThenTurnBack()
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
                watchdog?.cancel()
                watchdog = nil
                revivals = 0
                sessionActive = false
                presenting = false
                if let controller = controller {
                    self.controller = nil
                    controller.dismissThenTurnBack()
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
            // The list of sources may still be flying the film's logo into place: the page comes up when it lands.
            let hold = min(1.2, max(0, launch?.holdUntil?.timeIntervalSinceNow ?? 0))
            task?.cancel()
            task = Task { [weak self, weak view] in
                if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                await self?.present(immediate: immediate, from: view, makeRoot: makeRoot)
            }
        }

        private func present(immediate: Bool, from view: UIView?, makeRoot: @escaping () -> AnyView) async {
            presenting = true
            defer { presenting = false }
            guard let base = Coordinator.owner(of: view) else {
                sessionActive = false
                return
            }
            // The player of a title opened without a launch page waits for a sheet that is still leaving; the launch page does not wait
            // for the list to be gone: it goes over it, at once.
            if !immediate {
                // Only a page that is moving (a list closing after a tap) is waited for. A page that simply stays open, such as Live TV
                // or Universe shown over the tabs, used to be waited for until the time ran out: four seconds of nothing before every
                // channel started.
                for _ in 0..<40 {
                    if Task.isCancelled { return }
                    var moving = base.isBeingPresented || base.isBeingDismissed
                    var page: UIViewController = base
                    while let next = page.presentedViewController {
                        if next.isBeingPresented || next.isBeingDismissed { moving = true }
                        page = next
                    }
                    if !moving { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard !Task.isCancelled else { return }
            if let old = controller {
                controller = nil
                old.dismiss(animated: false)
            }
            if !immediate {
                // Without the launch page: exactly as the player always opened (it waited for the list to be gone, then came up over what
                // was left).
                var top: UIViewController = base
                while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
                OrientationController.set(.landscape)
                let host = LandscapeHostingController(rootView: makeRoot())
                host.modalPresentationStyle = .fullScreen
                host.view.backgroundColor = .black
                controller = host
                top.present(host, animated: false)
                router?.note("Apertura: pagina del lettore presentata (senza pagina nera)")
                startWatchdog(from: view, makeRoot: makeRoot)
                return
            }
            OrientationController.set(.landscape)
            let host = LandscapeHostingController(rootView: makeRoot())
            host.modalPresentationStyle = .fullScreen
            host.view.backgroundColor = .black
            // A source tapped the instant the list opens finds the list still sliding in: iOS refuses a page presented over a page that is
            // moving. Look again every tenth of a second (up to two seconds) until it is still, and check that the page really came up.
            for attempt in 0..<20 {
                if Task.isCancelled { return }
                var top: UIViewController = base
                while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
                // Only a page that is really sliding in or out counts as moving. A transition coordinator can stay around on a sheet that
                // is simply showing, and waiting for it made the black page give up and the old path (list, then player) take over.
                let moving = top.isBeingPresented || top.isBeingDismissed
                if !moving {
                    controller = host
                    top.present(host, animated: false)
                    if host.presentingViewController != nil {
                        router?.note("Apertura: pagina del lettore presentata (tentativo \(attempt + 1))")
                        startWatchdog(from: view, makeRoot: makeRoot)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // One last try, forced, over whatever is on top.
            var last: UIViewController = base
            while let next = last.presentedViewController { last = next }
            controller = host
            last.present(host, animated: false)
            if host.presentingViewController != nil {
                router?.note("Apertura: pagina del lettore presentata all'ultimo tentativo")
                startWatchdog(from: view, makeRoot: makeRoot)
                return
            }
            router?.note("Apertura: la pagina del lettore non è comparsa, riporto tutto com'era")
            // It never came up: leave everything as it was before the tap, so another tap works (no need to restart the app). The source
            // that is being prepared then opens the way it did before the black page existed.
            controller = nil
            sessionActive = false
            if let router = router {
                router.launch = nil
                if router.player != nil { router.player = nil }
            }
            OrientationController.restore()
        }

        /// While the player (or its black page) should be on screen, checks that it still is. A page under it that leaves (the list
        /// of sources dismissed by iOS while the screen turns) takes it away too, and nothing told the app: the page stayed off until
        /// the app was woken up again (Control Center, app switcher). It is put back at once instead.
        private func startWatchdog(from view: UIView?, makeRoot: @escaping () -> AnyView) {
            watchdog?.cancel()
            watchdog = Task { [weak self, weak view] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard let self = self, let router = self.router, !Task.isCancelled else { return }
                    // The run is over: nothing to keep up.
                    if router.launch == nil && router.player == nil { return }
                    guard let host = self.controller else { return }
                    if self.presenting || host.isBeingDismissed || host.isBeingPresented { continue }
                    guard host.presentingViewController == nil, self.revivals < 3 else { continue }
                    self.revivals += 1
                    router.note("Apertura: la pagina del lettore è stata tolta da iOS, la rimetto")
                    self.controller = nil
                    self.sessionActive = true
                    await self.present(immediate: router.launch != nil, from: view, makeRoot: makeRoot)
                    if self.controller == nil { return }
                }
            }
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
