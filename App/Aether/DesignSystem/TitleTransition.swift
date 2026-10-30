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

/// The title page that grows out of the poster with the same id.
private struct ZoomDestination: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace
    @EnvironmentObject private var settings: SettingsStore

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), settings.value.appearance.zoomTransition, let namespace = namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
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

    init(route: MetaRoute, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.label = label
    }

    var body: some View {
        if settings.value.appearance.detailAsCard {
            Button { router.detail = route } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .zoomSource(id: route.id)
        } else {
            NavigationLink(value: route) { label() }
                .zoomSource(id: route.id)
        }
    }
}
