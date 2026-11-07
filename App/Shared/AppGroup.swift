import Foundation

/// The App Group that lets the app and its widget share files. SideStore signs with the viewer's own team and renames the group for it,
/// so the name is not known in advance. It is read from where it is certainly written: the provisioning profile embedded in the app (and,
/// separately, in the widget), then the list SideStore puts in Info.plist (`ALTAppGroups`), then the name we asked for. The first one that
/// opens a container wins; without any, nothing is shared and everything that needs it quietly does nothing.
enum AppGroup {
    static let fallback = "group.app.aether.mediahub.pro"

    /// The groups the signature gives this bundle, from `embedded.mobileprovision`.
    static var profileGroups: [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"), start.lowerBound < end.upperBound else { return [] }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plist = (try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }

    static var plistGroups: [String] {
        return (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
    }

    /// Every name worth trying, ours first.
    static var candidates: [String] {
        var seen = Set<String>()
        let all = (profileGroups + plistGroups + [fallback]).filter { seen.insert($0).inserted }
        return all.filter { $0.hasPrefix(fallback) } + all.filter { !$0.hasPrefix(fallback) }
    }

    static var identifier: String? {
        for name in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) != nil { return name }
        return nil
    }

    static var containerURL: URL? {
        guard let name = identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name)
    }

    /// One line for the diagnostics page: what the signature gave and what worked.
    static var diagnosis: String {
        let profile = profileGroups.isEmpty ? "nessuno" : profileGroups.joined(separator: ", ")
        let plist = plistGroups.isEmpty ? "nessuno" : plistGroups.joined(separator: ", ")
        return "Profilo: \(profile) · Info.plist: \(plist) · usato: \(identifier ?? "nessuno (nessun contenitore condiviso)")"
    }
}
