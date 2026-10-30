import SwiftUI
import AetherCore

// MARK: - Ordering (pure)

enum DiscoverTypeOrdering {
    /// Moves the type `id` one place up (`delta` -1) or down (+1) among the available types, with exactly the result
    /// of dragging it there. Returns `state` unchanged when the move is impossible (first/last place, unknown type).
    static func moved(_ state: DiscoverLayoutState, id: String, by delta: Int) -> DiscoverLayoutState {
        let exposed = state.exposed
        var found: Int?
        for (index, entry) in exposed.enumerated() where entry.id == id {
            found = index
        }
        guard let index = found else { return state }
        let target = index + delta
        if target < 0 || target >= exposed.count { return state }
        // `List.onMove` semantics: the destination is an offset in the list as it was before the move.
        let destination = delta > 0 ? target + 1 : target
        var next = state
        next.move(fromOffsets: IndexSet(integer: index), toOffset: destination)
        return next
    }
}

// MARK: - Settings page

/// Settings > Scopri: which content types Discover offers, and in which order.
///
/// The list is not a fixed enumeration: it is whatever the installed addons provide (`CatalogCapabilities`), so a type
/// like TV, sport or music appears here by itself when an addon that serves it is installed. The choice is stored per
/// type id; types nobody serves right now are remembered but not shown.
struct DiscoverSettingsView: View {
    /// True when the page is shown in a sheet (from Discover), which needs its own way out.
    var showsCloseButton: Bool = false

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @Environment(\.dismiss) private var dismiss
    @State private var capabilities: CatalogCapabilities = CatalogCapabilities.empty
    @State private var hasLoaded = false
    @State private var editMode: EditMode = EditMode.inactive

    private static let footerText = "Trascina per riordinare (tocca «Riordina»), usa l'interruttore per nascondere una categoria da Scopri. L'elenco viene dagli addon installati: quando ne installi uno che offre un tipo nuovo (per esempio TV, sport o musica) compare qui da solo; se lo rimuovi la categoria sparisce, e se lo reinstalli ritrovi ordine e visibilità che avevi scelto."

    private var layoutState: DiscoverLayoutState {
        var ids: [String] = []
        for type in capabilities.availableTypes {
            ids.append(type.id)
        }
        return DiscoverLayout.normalise(stored: settings.value.content.discoverTypes, available: ids)
    }

    private var loadKey: String {
        return "\(addons.revision)-\(settings.value.content.hideAdultCatalogs)-\(settings.value.content.hideTalkShows)"
    }

    var body: some View {
        let state = layoutState
        Form {
            if !hasLoaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Leggo i tipi dagli addon…").foregroundStyle(Color.aetherSecondary)
                    }
                }
            } else if state.exposed.isEmpty {
                Section {
                    EmptyStateView(systemImage: "square.grid.2x2",
                                   title: "Nessuna categoria",
                                   message: "Le categorie di Scopri vengono dai cataloghi degli addon attivi. Installa un addon per vederle qui.")
                    NavigationLink("Gestisci gli addon") { AddonsView() }
                }
            } else {
                Section(header: Text("Categorie"), footer: Text(DiscoverSettingsView.footerText)) {
                    ForEach(state.exposed) { entry in
                        row(entry, state: state)
                    }
                    .onMove { source, destination in
                        moveTypes(from: source, to: destination)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Categorie di Scopri")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if showsCloseButton {
                    Button("Chiudi") { dismiss() }
                        .accessibilityIdentifier("settings.discover.close")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if state.exposed.count > 1 {
                    Button(editMode.isEditing ? "Fine" : "Riordina") {
                        withAnimation {
                            editMode = editMode.isEditing ? EditMode.inactive : EditMode.active
                        }
                    }
                    .accessibilityIdentifier("settings.discover.reorder")
                }
            }
        }
        .task(id: loadKey) { await refresh() }
    }

    private func row(_ entry: DiscoverTypeSetting, state: DiscoverLayoutState) -> some View {
        let info = ContentTypes.info(for: entry.id)
        var detail = ""
        if let capability = capabilities.capability(forType: entry.id) {
            detail = capability.feedCatalogCount == 1 ? "1 catalogo" : "\(capability.feedCatalogCount) cataloghi"
        }
        let exposed = state.exposed
        var position = 0
        for (index, candidate) in exposed.enumerated() where candidate.id == entry.id {
            position = index
        }
        let canMoveUp = position > 0
        let canMoveDown = position < exposed.count - 1
        return Toggle(isOn: visibility(for: entry.id)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                }
            } icon: {
                Image(systemName: info.symbolName)
            }
        }
        .accessibilityIdentifier("settings.discover.type.\(entry.id)")
        .accessibilityActions {
            if canMoveUp {
                Button("Sposta su") { moveType(entry.id, by: -1) }
            }
            if canMoveDown {
                Button("Sposta giù") { moveType(entry.id, by: 1) }
            }
        }
    }

    private func visibility(for id: String) -> Binding<Bool> {
        return Binding<Bool>(
            get: { return layoutState.isVisible(id) },
            set: { (value: Bool) in
                var next = layoutState
                next.setVisible(value, for: id)
                save(next)
            })
    }

    private func moveTypes(from source: IndexSet, to destination: Int) {
        var next = layoutState
        next.move(fromOffsets: source, toOffset: destination)
        save(next)
    }

    private func moveType(_ id: String, by delta: Int) {
        save(DiscoverTypeOrdering.moved(layoutState, id: id, by: delta))
    }

    /// Persists the whole list, including the entries of types that are not available right now.
    private func save(_ state: DiscoverLayoutState) {
        settings.value.content.discoverTypes = state.entries
    }

    private func refresh() async {
        let handles = await addons.handles()
        let hideAdult = settings.value.content.hideAdultCatalogs
        capabilities = CatalogCapabilities.build(handles: handles, hideAdultCatalogs: hideAdult)
        hasLoaded = true
    }
}
