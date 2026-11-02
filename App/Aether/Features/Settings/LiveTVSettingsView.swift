import SwiftUI
import AetherCore

/// Impostazioni ▸ Riproduzione ▸ Cataloghi TV in diretta: quali cataloghi di canali mostrare (Scopri, Home) e quali usare nella ricerca.
struct LiveTVSettingsView: View {
    @EnvironmentObject private var addons: AddonStore

    private struct Row: Identifiable {
        let addon: InstalledAddon
        let catalog: ManifestCatalog
        var id: String { return addon.id.uuidString + "/" + catalog.key }
    }

    private var rows: [Row] {
        var found: [Row] = []
        for addon in addons.addons {
            for catalog in addon.manifest.catalogs where ContentTypes.canonicalID(catalog.type) == "tv" {
                found.append(Row(addon: addon, catalog: catalog))
            }
        }
        return found
    }

    var body: some View {
        Form {
            if rows.isEmpty {
                Section {
                    Text("Nessun addon installato offre cataloghi di TV in diretta.").foregroundStyle(Color.aetherSecondary)
                }
            }
            ForEach(addons.addons.filter { addon in rows.contains { $0.addon.id == addon.id } }) { addon in
                Section(header: Text(addon.displayName)) {
                    ForEach(rows.filter { $0.addon.id == addon.id }) { row in
                        if row.catalog.supportsSearch && !row.catalog.isPlainFeed && DiscoverFiltering.serverFilter(for: row.catalog) == nil {
                            Toggle(isOn: Binding(
                                get: { row.addon.isCatalogSearchable(row.catalog) },
                                set: { value in Task { await addons.setCatalogVisible(value, catalogKey: InstalledAddon.searchKey(row.catalog), id: row.addon.id) } })) {
                                label(row, detail: "usato nella ricerca")
                            }
                        } else {
                            Toggle(isOn: Binding(
                                get: { row.addon.isCatalogVisible(row.catalog) },
                                set: { value in Task { await addons.setCatalogVisible(value, catalogKey: row.catalog.key, id: row.addon.id) } })) {
                                label(row, detail: DiscoverFiltering.serverFilter(for: row.catalog)?.isRequired == true
                                      ? "in Scopri, scelta del gruppo obbligatoria" : "in Scopri e Home")
                            }
                        }
                    }
                }
            }
            Section(footer: Text("Spegnere un catalogo lo nasconde da Scopri e Home; per i moduli di ricerca l'interruttore decide se partecipano alla ricerca. Il lettore per le dirette si sceglie in Riproduzione ▸ Motore.")) {
                EmptyView()
            }
        }
        .navigationTitle("TV in diretta")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(_ row: Row, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.catalog.name)
            Text(detail).font(.caption).foregroundStyle(Color.aetherSecondary)
        }
    }
}
