import Foundation

/// The App Group that lets the app and its widget share files. SideStore signs with the viewer's own team and renames the group for it:
/// the real name is written in Info.plist (`ALTAppGroups`). Without the group (the signature did not provide it) there is no container
/// and everything that needs it quietly does nothing.
enum AppGroup {
    static let fallback = "group.app.aether.mediahub"

    static var identifier: String {
        return (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])?.first ?? fallback
    }

    static var containerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
