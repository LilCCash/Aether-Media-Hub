import SwiftUI

/// Text drawn over artwork: a soft dark shadow keeps it readable on bright pictures (Aspetto › «Ombra sotto i testi sulle
/// immagini»). Off, the text is drawn exactly as before.
struct LegibleOnArtwork: ViewModifier {
    @EnvironmentObject private var settings: SettingsStore

    func body(content: Content) -> some View {
        if settings.value.appearance.legibilityScrims {
            content
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.35), radius: 8)
        } else {
            content
        }
    }
}

extension View {
    func legibleOnArtwork() -> some View { modifier(LegibleOnArtwork()) }
}
