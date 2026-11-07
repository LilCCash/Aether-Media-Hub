import SwiftUI

/// The Aether dock: a floating glass capsule with the five places of the app. It replaces the system tab bar.
struct AetherDock: View {
    @Binding var selection: AppTab
    @EnvironmentObject private var settings: SettingsStore

    private struct Item: Identifiable {
        let tab: AppTab
        let title: String
        let symbol: String
        var id: String { return tab.rawValue }
    }

    private let items = [
        Item(tab: .home, title: "Home", symbol: "house.fill"),
        Item(tab: .discover, title: "Scopri", symbol: "safari.fill"),
        Item(tab: .library, title: "Libreria", symbol: "books.vertical.fill"),
        Item(tab: .search, title: "Cerca", symbol: "magnifyingglass"),
        Item(tab: .more, title: "Altro", symbol: "ellipsis"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = selection == item.tab
                Button {
                    if selection != item.tab { UISelectionFeedbackGenerator().selectionChanged() }
                    withAnimation(settings.animationsEnabled ? .spring(response: 0.32, dampingFraction: 0.8) : nil) { selection = item.tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 19, weight: .semibold))
                        Text(item.title).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background {
                        if selected {
                            Capsule().fill(LinearGradient(colors: [settings.accentColor.opacity(0.85), settings.accentColor.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                                .shadow(color: settings.accentColor.opacity(0.55), radius: 10, y: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("dock.\(item.tab.rawValue)")
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(Color(red: 0.05, green: 0.04, blue: 0.16).opacity(0.7)))
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .ignoresSafeArea(.keyboard)
    }
}
