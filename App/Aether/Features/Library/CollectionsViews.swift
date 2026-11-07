import SwiftUI
import AetherCore

/// «Collezioni» in the Library: the viewer's own lists.
struct CollectionsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var newName = ""
    @State private var creating = false
    @State private var renaming: LibraryCollection?
    @State private var renameText = ""

    private var lists: [LibraryCollection] { return settings.value.content.collections.collections }

    var body: some View {
        List {
            if lists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 40)).foregroundStyle(Color.aetherSecondary)
                    Text("Nessuna collezione").font(.headline)
                    Text("Crea una lista (per esempio «Da vedere con Marta») e aggiungi i titoli dalla loro scheda.").font(.subheadline).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40).listRowBackground(Color.clear)
            }
            ForEach(lists) { list in
                NavigationLink {
                    CollectionDetailView(collectionID: list.id)
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: -14) {
                            ForEach(Array(list.items.prefix(3).enumerated()), id: \.element.id) { _, item in
                                RemoteImage(urlString: item.poster, width: 100, placeholderSeed: item.name, systemPlaceholder: "film")
                                    .frame(width: 38, height: 56).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
                            }
                            if list.items.isEmpty { Image(systemName: "rectangle.stack").font(.title2).frame(width: 38, height: 56).foregroundStyle(Color.aetherSecondary) }
                        }
                        .frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.name).font(.headline)
                            Text("\(list.items.count) titoli").font(.caption).foregroundStyle(Color.aetherSecondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { settings.value.content.collections.delete(id: list.id) } label: { Label("Elimina", systemImage: "trash") }
                    Button { renaming = list; renameText = list.name } label: { Label("Rinomina", systemImage: "pencil") }.tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .toolbar { ToolbarItem(placement: .bottomBar) { Button { creating = true } label: { Label("Nuova collezione", systemImage: "plus.circle.fill") } } }
        .alert("Nuova collezione", isPresented: $creating) {
            TextField("Nome", text: $newName)
            Button("Crea") { settings.value.content.collections.create(name: newName); newName = "" }
            Button("Annulla", role: .cancel) { newName = "" }
        }
        .alert("Rinomina", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $renameText)
            Button("Salva") { if let list = renaming { settings.value.content.collections.rename(id: list.id, to: renameText) }; renaming = nil }
            Button("Annulla", role: .cancel) { renaming = nil }
        }
    }
}

struct CollectionDetailView: View {
    let collectionID: String
    @EnvironmentObject private var settings: SettingsStore
    private var list: LibraryCollection? { return settings.value.content.collections.collections.first { $0.id == collectionID } }

    var body: some View {
        ZStack {
            AetherBackdrop()
            if let list = list {
                if list.items.isEmpty {
                    Text("La collezione è vuota.").foregroundStyle(Color.aetherSecondary)
                } else {
                    ScrollView {
                        AdaptiveCardGrid(items: list.items, minColumns: 3, preferredWidth: 130, spacing: 12, rowSpacing: 20) { item, width in
                            TitleLink(route: MetaRoute(type: item.type, id: item.id, preview: MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster))) {
                                PosterCard(meta: MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster), width: width)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { settings.value.content.collections.remove(itemID: item.id, from: collectionID) } label: { Label("Togli dalla collezione", systemImage: "minus.circle") }
                            }
                        }
                        .padding(.vertical, Theme.pageMargin)
                    }
                }
            }
        }
        .navigationTitle(list?.name ?? "Collezione")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// «Aggiungi a una collezione» on a title page.
struct AddToCollectionMenu: View {
    let meta: MetaItem
    @EnvironmentObject private var settings: SettingsStore
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        let lists = settings.value.content.collections.collections
        Menu {
            ForEach(lists) { list in
                let inside = list.items.contains { $0.id == meta.id }
                Button {
                    if inside { settings.value.content.collections.remove(itemID: meta.id, from: list.id) }
                    else { settings.value.content.collections.add(CollectionItem(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster), to: list.id) }
                } label: { Label(list.name, systemImage: inside ? "checkmark.circle.fill" : "circle") }
            }
            Button { creating = true } label: { Label("Nuova collezione…", systemImage: "plus") }
        } label: {
            Label("Collezioni", systemImage: "rectangle.stack.badge.plus").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("detail.collections")
        .alert("Nuova collezione", isPresented: $creating) {
            TextField("Nome", text: $name)
            Button("Crea e aggiungi") {
                if let list = settings.value.content.collections.create(name: name) {
                    settings.value.content.collections.add(CollectionItem(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster), to: list.id)
                }
                name = ""
            }
            Button("Annulla", role: .cancel) { name = "" }
        }
    }
}
