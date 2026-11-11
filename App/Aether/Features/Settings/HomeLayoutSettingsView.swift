import SwiftUI
import AetherCore

/// Settings > Aspetto > Personalizza la Home: which sections the Home shows, in which order, how their cards look and how
/// big they are, how the featured carousel looks, and an optional greeting.
struct HomeLayoutSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var editMode: EditMode = EditMode.inactive
    @State private var confirmingReset = false

    private static let footerText = "Usa l'interruttore per nascondere una sezione. Tocca «Riordina» per cambiare l'ordine, oppure usa le azioni «Sposta su» e «Sposta giù» di VoiceOver. Per ogni sezione scegli come sono fatte le schede e quanto sono grandi: «Auto» segue la dimensione generale scelta in Aspetto. Le sezioni vuote non vengono mai mostrate."

    private var isGlass: Bool { return settings.value.appearance.homeLayout == .glass }
    /// The sections being edited: the classic Home's or the glass Home's (each layout keeps its own order and choices).
    private var sectionsPath: WritableKeyPath<AppSettings, [HomeSectionConfig]> {
        return isGlass ? \.appearance.glassHome.sections : \.appearance.homeSections
    }
    private func current(_ id: String) -> HomeSectionConfig {
        return settings.value[keyPath: sectionsPath].first(where: { $0.id == id }) ?? HomeSectionConfig(id: id)
    }

    var body: some View {
        let sections = settings.value[keyPath: sectionsPath]
        Form {
            Section(header: Text("Layout"),
                    footer: Text(isGlass
                                 ? "Vetrina: in alto il nome di Aether e la tua foto (tocca la foto per il profilo), poi la ricerca, le categorie e le sezioni su schede di vetro; «In evidenza» si accende tra le sezioni qui sotto. In basso: Home, Libreria e Impostazioni, con Cerca a parte; Scopri si apre dalle categorie, i download sono in Libreria."
                                 : "Classica: l'immagine in evidenza e le righe dei cataloghi, con Home, Scopri, Libreria, Profilo e Cerca in basso.")) {
                Picker("Layout della Home", selection: settings.binding(\.appearance.homeLayout)) {
                    ForEach(HomeLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.home.layout")
            }
            if isGlass {
                Section(header: Text("Intestazione"),
                        footer: Text("Il saluto usa il nome qui sotto, se c'è («Ciao, Giulia!»). Il nome resta su questo dispositivo, ma finisce nel backup delle impostazioni, che non è cifrato.")) {
                    Toggle("Nome di Aether", isOn: settings.binding(\.appearance.glassHome.showLogo))
                    Toggle("Foto del profilo", isOn: settings.binding(\.appearance.glassHome.showAvatar))
                        .accessibilityIdentifier("settings.home.glass.avatar")
                    Toggle("Saluto", isOn: settings.binding(\.appearance.glassHome.showGreeting))
                    if settings.value.appearance.glassHome.showGreeting {
                        TextField("Il tuo nome (facoltativo)", text: nameBinding)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    }
                    NavigationLink { HomeCategoriesSettingsView() } label: {
                        LabeledContent("Categorie", value: "\(settings.value.appearance.glassHome.categories.filter { $0.isVisible }.count) visibili")
                    }
                    .accessibilityIdentifier("settings.home.categories")
                }
            }
            Section(header: Text("Sezioni"), footer: Text(HomeLayoutSettingsView.footerText)) {
                ForEach(sections) { section in
                    row(section, in: sections)
                }
                .onMove { source, destination in
                    var next = sections
                    next.move(fromOffsets: source, toOffset: destination)
                    settings.value[keyPath: sectionsPath] = next
                }
            }
            if !isGlass {
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
            }
            Section {
                Button("Ripristina Home predefinita") { confirmingReset = true }
                    .accessibilityIdentifier("settings.home.reset")
            }
        }
        .environment(\.editMode, $editMode)
        .aetherPage()
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
            Button("Ripristina", role: .destructive) {
                let defaults = AppearanceSettings()
                settings.value.appearance.homeLayout = defaults.homeLayout
                settings.value.appearance.glassHome = defaults.glassHome
                settings.value.appearance.homeSections = HomeSectionConfig.defaultOrder
                settings.value.appearance.heroStyle = defaults.heroStyle
                settings.value.appearance.heroAutoScroll = defaults.heroAutoScroll
                settings.value.appearance.heroInterval = defaults.heroInterval
                settings.value.appearance.heroEdgeToEdge = defaults.heroEdgeToEdge
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Torna la Home classica; sezioni, categorie, ordine e schede di entrambe le Home tornano come all'inizio. Le altre impostazioni non cambiano.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ section: HomeSectionConfig, in sections: [HomeSectionConfig]) -> some View {
        let styles = HomeCardStyle.allowed(for: section.id)
        let showsOptions = section.isVisible && !editMode.isEditing
        VStack(alignment: .leading, spacing: 10) {
            Toggle(GlassHomeSettings.title(for: section.id), isOn: visibility(section.id))
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
            if settings.value.appearance.heroStyle == .fullBleed {
                Toggle(isOn: settings.binding(\.appearance.heroEdgeToEdge)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Immagine fino al bordo alto")
                        Text("Quando «In evidenza» è la prima sezione, l'immagine sale sotto l'orologio e la pagina non mostra il titolo «Home».")
                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                }
            }
            Toggle("Scorrimento automatico", isOn: settings.binding(\.appearance.heroAutoScroll))
                .accessibilityIdentifier("settings.home.heroAutoScroll")
            if settings.value.appearance.heroAutoScroll {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Intervallo tra un film e l'altro", value: "\(Int(settings.value.appearance.heroInterval)) s")
                    Slider(value: settings.binding(\.appearance.heroInterval), in: 3...20, step: 1)
                        .accessibilityLabel("Intervallo di scorrimento in secondi")
                        .accessibilityIdentifier("settings.home.heroInterval")
                }
            }
            Text(settings.value.appearance.heroStyle == .fullBleed
                 ? "L'immagine occupa tutta la larghezza e sfuma nella pagina, con il titolo in sovrimpressione."
                 : "Una scheda con gli angoli arrotondati e il titolo sopra l'immagine.")
                .font(.caption).foregroundStyle(Color.aetherSecondary)
            HeroPreview(style: settings.value.appearance.heroStyle)
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
            HomeCardPreview(style: section.effectiveStyle ?? .poster, size: section.size ?? .medium)
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
        return Binding(get: { current(id).isVisible },
                       set: { value in update(id) { $0.isVisible = value } })
    }

    private func styleBinding(_ id: String) -> Binding<HomeCardStyle> {
        return Binding(get: { current(id).effectiveStyle ?? .poster },
                       set: { value in
                           // The section's own default is stored as "no choice" so a future default still applies.
                           update(id) { $0.style = value == HomeCardStyle.defaultStyle(for: id) ? nil : value }
                       })
    }

    private func sizeBinding(_ id: String) -> Binding<PosterSize?> {
        return Binding(get: { current(id).size },
                       set: { value in update(id) { $0.size = value } })
    }

    private func update(_ id: String, _ change: (inout HomeSectionConfig) -> Void) {
        guard let index = settings.value[keyPath: sectionsPath].firstIndex(where: { $0.id == id }) else { return }
        change(&settings.value[keyPath: sectionsPath][index])
    }

    private func move(_ id: String, by delta: Int) {
        settings.value[keyPath: sectionsPath] = HomeSectionOrdering.moved(settings.value[keyPath: sectionsPath], id: id, by: delta)
    }
}

/// The categories of the glass Home: which are shown, their name, their symbol and their order.
struct HomeCategoriesSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @State private var editMode: EditMode = EditMode.inactive

    private var categories: [HomeCategory] { return settings.value.appearance.glassHome.categories }

    var body: some View {
        Form {
            Section(footer: Text("Una categoria apre Scopri sul suo tipo (Live TV apre Live TV). Compare solo se un addon installato ha cataloghi di quel tipo. Tocca «Riordina» per cambiare l'ordine.")) {
                ForEach(categories) { category in
                    row(category)
                }
                .onMove { source, destination in
                    var next = categories
                    next.move(fromOffsets: source, toOffset: destination)
                    settings.value.appearance.glassHome.categories = next
                }
            }
            Section {
                Button("Ripristina le categorie") {
                    settings.value.appearance.glassHome.categories = HomeCategory.normalise([])
                }
            }
        }
        .environment(\.editMode, $editMode)
        .aetherPage()
        .navigationTitle("Categorie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Fine" : "Riordina") {
                    withAnimation { editMode = editMode.isEditing ? EditMode.inactive : EditMode.active }
                }
            }
        }
    }

    private func row(_ category: HomeCategory) -> some View {
        HStack(spacing: Space.m) {
            NavigationLink {
                HomeCategorySymbolPicker(selection: binding(category.id, \.symbol))
            } label: {
                Image(systemName: category.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
            }
            .fixedSize()
            .accessibilityLabel("Simbolo di \(category.title)")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Nome", text: binding(category.id, \.title))
                    .font(.body.weight(.medium))
                    .submitLabel(.done)
                if !isAvailable(category) {
                    Text("Nessun addon installato offre questo tipo").font(.caption).foregroundStyle(Color.aetherSecondary)
                }
            }
            Toggle("Mostra \(category.title)", isOn: binding(category.id, \.isVisible)).labelsHidden()
        }
        .accessibilityIdentifier("settings.home.category.\(category.id)")
    }

    private func isAvailable(_ category: HomeCategory) -> Bool {
        if category.opensLiveTV { return true }
        let wanted = ContentTypes.canonicalID(category.id)
        return addons.enabledAddons.contains { $0.manifest.catalogs.contains { ContentTypes.canonicalID($0.type) == wanted } }
    }

    private func binding<T>(_ id: String, _ path: WritableKeyPath<HomeCategory, T>) -> Binding<T> {
        return Binding(get: {
            let category = settings.value.appearance.glassHome.categories.first { $0.id == id } ?? HomeCategory.available.first { $0.id == id }!
            return category[keyPath: path]
        }, set: { value in
            guard let index = settings.value.appearance.glassHome.categories.firstIndex(where: { $0.id == id }) else { return }
            var category = settings.value.appearance.glassHome.categories[index]
            category[keyPath: path] = value
            if let text = value as? String, (path as AnyKeyPath) == (\HomeCategory.title as AnyKeyPath) { category.title = String(text.prefix(24)) }
            settings.value.appearance.glassHome.categories[index] = category
        })
    }
}

/// The symbols a category can have.
struct HomeCategorySymbolPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Space.m)], spacing: Space.m) {
                ForEach(HomeCategory.symbols, id: \.self) { symbol in
                    Button {
                        selection = symbol
                        Haptics.select()
                        dismiss()
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .medium))
                            .frame(width: 64, height: 64)
                            .foregroundStyle(symbol == selection ? Color.accentColor.readableForeground : Color.primary)
                            .background(symbol == selection ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.aetherSurface),
                                        in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(symbol == selection ? .isSelected : [])
                }
            }
            .padding(Theme.pageMargin)
        }
        .aetherPage()
        .navigationTitle("Simbolo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
