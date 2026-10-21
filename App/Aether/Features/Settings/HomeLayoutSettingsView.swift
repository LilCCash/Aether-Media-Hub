import SwiftUI
import AetherCore

/// Settings > Aspetto > Personalizza la Home: which sections the Home shows, in which order, how their cards look and how
/// big they are, how the featured carousel looks, and an optional greeting.
struct HomeLayoutSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var editMode: EditMode = EditMode.inactive
    @State private var confirmingReset = false

    private static let footerText = "Usa l'interruttore per nascondere una sezione. Tocca «Riordina» per cambiare l'ordine, oppure usa le azioni «Sposta su» e «Sposta giù» di VoiceOver. Per ogni sezione scegli come sono fatte le schede e quanto sono grandi: «Auto» segue la dimensione generale scelta in Aspetto. Le sezioni vuote non vengono mai mostrate."

    var body: some View {
        let sections = settings.value.appearance.homeSections
        Form {
            Section(header: Text("Sezioni"), footer: Text(HomeLayoutSettingsView.footerText)) {
                ForEach(sections) { section in
                    row(section, in: sections)
                }
                .onMove { source, destination in
                    var next = sections
                    next.move(fromOffsets: source, toOffset: destination)
                    settings.value.appearance.homeSections = next
                }
            }
            Section(header: Text("Saluto"),
                    footer: Text("Una riga in cima alla Home, per esempio «Buonasera, Giulia». Il nome resta su questo dispositivo, ma finisce nel backup delle impostazioni, che non è cifrato.")) {
                Toggle("Mostra un saluto", isOn: settings.binding(\.appearance.greetingEnabled))
                    .accessibilityIdentifier("settings.home.greeting")
                if settings.value.appearance.greetingEnabled {
                    TextField("Il tuo nome (facoltativo)", text: nameBinding)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("settings.home.greetingName")
                }
            }
            Section {
                Button("Ripristina la Home") { confirmingReset = true }
                    .accessibilityIdentifier("settings.home.reset")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Personalizza la Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Fine" : "Riordina") {
                    withAnimation { editMode = editMode.isEditing ? EditMode.inactive : EditMode.active }
                }
                .accessibilityIdentifier("settings.home.reorder")
            }
        }
        .confirmationDialog("Ripristinare la Home?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Ripristina ordine, stili e dimensioni", role: .destructive) {
                settings.value.appearance.homeSections = HomeSectionConfig.defaultOrder
                settings.value.appearance.heroStyle = .card
                settings.value.appearance.heroAutoScroll = true
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Le sezioni tornano all'ordine originale, tutte visibili, con le schede di Aether 1.0.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ section: HomeSectionConfig, in sections: [HomeSectionConfig]) -> some View {
        let styles = HomeCardStyle.allowed(for: section.id)
        let showsOptions = section.isVisible && !editMode.isEditing
        VStack(alignment: .leading, spacing: 10) {
            Toggle(HomeSectionConfig.title(for: section.id), isOn: visibility(section.id))
                .accessibilityIdentifier("settings.home.section.\(section.id)")
            if showsOptions && section.id == HomeSectionConfig.hero {
                heroOptions
            } else if showsOptions && !styles.isEmpty {
                cardOptions(section, styles: styles)
            }
        }
        .padding(.vertical, 2)
        .accessibilityActions {
            if HomeSectionOrdering.canMove(sections, id: section.id, by: -1) {
                Button("Sposta su") { move(section.id, by: -1) }
            }
            if HomeSectionOrdering.canMove(sections, id: section.id, by: 1) {
                Button("Sposta giù") { move(section.id, by: 1) }
            }
        }
    }

    private var heroOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Aspetto")
            Picker("Aspetto della sezione In evidenza", selection: settings.binding(\.appearance.heroStyle)) {
                ForEach(HeroStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.home.heroStyle")
            Toggle("Scorrimento automatico", isOn: settings.binding(\.appearance.heroAutoScroll))
                .accessibilityIdentifier("settings.home.heroAutoScroll")
            Text(settings.value.appearance.heroStyle == .fullBleed
                 ? "L'immagine occupa tutta la larghezza e sfuma nella pagina, con il titolo in sovrimpressione."
                 : "Una scheda con gli angoli arrotondati e il titolo sopra l'immagine.")
                .font(.caption).foregroundStyle(Color.aetherSecondary)
        }
    }

    private func cardOptions(_ section: HomeSectionConfig, styles: [HomeCardStyle]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if styles.count > 1 {
                caption("Schede")
                Picker("Stile delle schede", selection: styleBinding(section.id)) {
                    ForEach(styles, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.home.style.\(section.id)")
            }
            if (section.effectiveStyle ?? .poster) != .compact {
                caption("Dimensione")
                Picker("Dimensione delle schede", selection: sizeBinding(section.id)) {
                    Text("Auto").tag(PosterSize?.none)
                    ForEach(PosterSize.allCases, id: \.self) { Text($0.title).tag(PosterSize?.some($0)) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.home.size.\(section.id)")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Color.aetherSecondary).accessibilityHidden(true)
    }

    // MARK: Bindings

    private var nameBinding: Binding<String> {
        return Binding(get: { settings.value.appearance.greetingName },
                       set: { settings.value.appearance.greetingName = String($0.prefix(Greeting.maxNameLength)) })
    }

    private func visibility(_ id: String) -> Binding<Bool> {
        return Binding(get: { settings.value.appearance.section(id).isVisible },
                       set: { value in update(id) { $0.isVisible = value } })
    }

    private func styleBinding(_ id: String) -> Binding<HomeCardStyle> {
        return Binding(get: { settings.value.appearance.section(id).effectiveStyle ?? .poster },
                       set: { value in
                           // The section's own default is stored as "no choice" so a future default still applies.
                           update(id) { $0.style = value == HomeCardStyle.defaultStyle(for: id) ? nil : value }
                       })
    }

    private func sizeBinding(_ id: String) -> Binding<PosterSize?> {
        return Binding(get: { settings.value.appearance.section(id).size },
                       set: { value in update(id) { $0.size = value } })
    }

    private func update(_ id: String, _ change: (inout HomeSectionConfig) -> Void) {
        guard let index = settings.value.appearance.homeSections.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.value.appearance.homeSections[index])
    }

    private func move(_ id: String, by delta: Int) {
        settings.value.appearance.homeSections = HomeSectionOrdering.moved(settings.value.appearance.homeSections, id: id, by: delta)
    }
}
