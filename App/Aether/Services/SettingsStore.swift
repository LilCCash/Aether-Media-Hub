import SwiftUI
import AetherCore

/// Thread-safe copy of the settings the networking layer needs from background contexts.
final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    init(_ settings: AppSettings) {
        self.settings = settings
    }

    func set(_ new: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        settings = new
    }

    func get() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }
}

/// Persistent, observable settings. Every change is written immediately and pushed to the collaborators
/// that implement the behaviour (network policy, library policy, caches, logging).
@MainActor
final class SettingsStore: ObservableObject {
    private static let defaultsKey = "aether.settings.v1"

    @Published var value: AppSettings {
        didSet {
            guard value != oldValue else { return }
            AetherTypography.design = AetherTypography.fontDesign(for: value.appearance.titleFont)
            persist()
            snapshot.set(value)
            onChange?(value, oldValue)
        }
    }

    let snapshot: SettingsSnapshot
    private let defaults: UserDefaults
    var onChange: ((AppSettings, AppSettings) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = AppSettings()
        if let data = defaults.data(forKey: SettingsStore.defaultsKey),
           let decoded = try? JSONDecoder.aether().decode(AppSettings.self, from: data) {
            loaded = decoded
        }
        self.value = loaded
        self.snapshot = SettingsSnapshot(loaded)
        AetherTypography.design = AetherTypography.fontDesign(for: loaded.appearance.titleFont)
    }

    private func persist() {
        if let data = try? JSONEncoder.aether().encode(value) {
            defaults.set(data, forKey: SettingsStore.defaultsKey)
        }
    }

    func resetToDefaults() {
        value = AppSettings()
    }

    /// `Binding` into any nested setting, e.g. `settings.binding(\.playback.autoResume)`.
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        return Binding(get: { self.value[keyPath: keyPath] },
                       set: { self.value[keyPath: keyPath] = $0 })
    }

    // MARK: Derived presentation values

    var colorScheme: ColorScheme? {
        switch value.appearance.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accentColor: Color { value.appearance.customAccentHex.map { Color(hex: $0) } ?? Theme.accent(for: value.appearance.accent) }

    var animationsEnabled: Bool { value.appearance.animationsEnabled }
    var reduceEffects: Bool { value.appearance.reduceVisualEffects }

    /// Two-letter language derived from the setting (`system` → first preferred locale).
    static func resolvedLanguage(_ setting: String) -> String? {
        switch setting {
        case "off": return nil
        case "system": return Locale.preferredLanguages.first.map { LanguageCodes.normalise($0) }
        default: return LanguageCodes.normalise(setting)
        }
    }
}
