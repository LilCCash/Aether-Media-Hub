import SwiftUI

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The namespace the poster zoom is matched in (set once, at the root).
    var zoomNamespace: Namespace.ID? {
        get { return self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// A poster (or banner) that a title page opens from by zooming (iOS 18 and later, when the viewer turned it on).
private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace
    @EnvironmentObject private var settings: SettingsStore

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), settings.value.appearance.zoomTransition, let namespace = namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// The title page that grows out of the poster it was opened from (the exact card that was tapped, when the title is in several rows).
private struct ZoomDestination: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter

    private var sourceID: String {
        if let tapped = router.zoomSourceID, tapped.hasPrefix(id + "#") { return tapped }
        return id
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), settings.value.appearance.zoomTransition, let namespace = namespace {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    func zoomSource(id: String) -> some View { modifier(ZoomSource(id: id)) }
    func zoomDestination(id: String) -> some View { modifier(ZoomDestination(id: id)) }
}

/// Opens a title: as a card that comes up over the screen, or pushed full screen, as the viewer chose in the settings.
struct TitleLink<Label: View>: View {
    private let route: MetaRoute
    private let label: () -> Label
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    /// This card's own zoom id: the same title in two rows must not share one, or the page would grow out of the wrong card.
    @State private var token = UUID().uuidString

    init(route: MetaRoute, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.label = label
    }

    var body: some View {
        let sourceID = route.id + "#" + token
        if settings.value.appearance.detailAsCard {
            Button { Haptics.tap(); router.zoomSourceID = sourceID; router.detail = route } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.pressable)
                .zoomSource(id: sourceID)
        } else {
            NavigationLink(value: route) { label() }
                .simultaneousGesture(TapGesture().onEnded { router.zoomSourceID = sourceID })
                .zoomSource(id: sourceID)
        }
    }
}
