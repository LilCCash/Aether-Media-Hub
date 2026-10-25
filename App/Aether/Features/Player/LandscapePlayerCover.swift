import SwiftUI
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
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
}

/// Presents the player (full screen, sideways) for a `PlayerRequest` and dismisses it when the request is cleared. Replaces
/// `fullScreenCover(item:)` for the player, both over the app and over Theater Mode.
struct LandscapePlayerCover: ViewModifier {
    @Binding var item: PlayerRequest?
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.aetherStyle) private var style
    @Environment(\.imageLoader) private var loader

    func body(content: Content) -> some View {
        content.background(
            PlayerPresenter(item: item,
                            makeRoot: { request in
                                AnyView(PlayerView(request: request, env: env)
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
                            dismissed: { item = nil })
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

private struct PlayerPresenter: UIViewRepresentable {
    let item: PlayerRequest?
    let makeRoot: (PlayerRequest) -> AnyView
    let dismissed: () -> Void

    func makeCoordinator() -> Coordinator { return Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.alpha = 0
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.sync(item: item, view: view, makeRoot: makeRoot)
    }

    @MainActor
    final class Coordinator {
        private var controller: LandscapeHostingController?
        private var presentedID: UUID?
        private var task: Task<Void, Never>?

        func sync(item: PlayerRequest?, view: UIView, makeRoot: @escaping (PlayerRequest) -> AnyView) {
            guard let item = item else {
                task?.cancel()
                task = nil
                presentedID = nil
                if let controller = controller {
                    self.controller = nil
                    controller.dismiss(animated: false)
                }
                return
            }
            guard presentedID != item.id else { return }
            presentedID = item.id
            task?.cancel()
            task = Task { [weak self, weak view] in
                await self?.present(item, from: view, makeRoot: makeRoot)
            }
        }

        private func present(_ item: PlayerRequest, from view: UIView?, makeRoot: (PlayerRequest) -> AnyView) async {
            guard let base = Coordinator.owner(of: view) else { return }
            // Wait for a sheet or a full-screen page that is still leaving (the source list closes just before the player opens).
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if base.presentedViewController == nil && !base.isBeingPresented && !base.isBeingDismissed { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            if let old = controller {
                controller = nil
                old.dismiss(animated: false)
            }
            var top: UIViewController = base
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            OrientationController.set(.landscape)
            let host = LandscapeHostingController(rootView: makeRoot(item))
            host.modalPresentationStyle = .fullScreen
            host.view.backgroundColor = .black
            controller = host
            top.present(host, animated: false)
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
    func landscapePlayer(_ item: Binding<PlayerRequest?>) -> some View {
        return modifier(LandscapePlayerCover(item: item))
    }
}
