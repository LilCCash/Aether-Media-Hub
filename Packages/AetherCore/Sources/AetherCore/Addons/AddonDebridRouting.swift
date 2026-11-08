import Foundation

/// Which debrid service an addon is meant for, chosen by the viewer on the addon's page. `both` (the default, also for every addon
/// saved before this existed) keeps the addon in use whatever service is active.
public enum AddonDebridScope: String, Codable, CaseIterable, Sendable {
    case both, torbox, realDebrid

    public var title: String {
        switch self {
        case .both: return "Entrambi"
        case .torbox: return "TorBox"
        case .realDebrid: return "Real-Debrid"
        }
    }
}

/// The debrid service in use when sources are asked for. `realDebridKey` is the viewer's Real-Debrid API token: it only ever goes
/// into the address of an addon the viewer installed (as if they had typed it on that addon's configuration page), never into a log.
public struct StreamDebridContext: Sendable, Equatable {
    public enum Service: String, Sendable { case torbox, realDebrid }
    public var service: Service
    public var realDebridKey: String?

    public init(service: Service, realDebridKey: String? = nil) {
        self.service = service
        self.realDebridKey = realDebridKey
    }
}

/// How the sources of an addon are asked for, given the active debrid service:
/// - TorBox active: every addon exactly as installed; only the ones the viewer marked «Real-Debrid» are left out.
/// - Real-Debrid active: the ones marked «TorBox» are left out; the ones marked «Real-Debrid» are used as installed; the ones
///   marked «Entrambi» that Aether knows how to configure (Torrentio, Comet) are asked with Real-Debrid and the viewer's key in
///   place of their own debrid, set to give only the sources already ready on Real-Debrid. The saved addon never changes.
public enum AddonDebridRouting {
    /// The addons Aether can switch to Real-Debrid by itself.
    public enum Kind: String, Sendable { case torrentio, comet }

    public static func kind(host: String) -> Kind? {
        let host = host.lowercased()
        if host.contains("torrentio") { return .torrentio }
        if host.contains("comet") { return .comet }
        return nil
    }

    /// What to do with one addon when sources are asked for.
    public enum Decision: Equatable, Sendable {
        /// Ask this address; `switched` names the addon when the address was switched to Real-Debrid.
        case use(URL, switched: Kind?)
        /// The viewer meant this addon for the other service.
        case skip
        /// A Torrentio or Comet whose address could not be read: it is not asked, so that sources of the other service do not
        /// slip in while Real-Debrid is active.
        case unreadable(Kind)
    }

    public static func decide(_ handle: AddonHandle, context: StreamDebridContext?) -> Decision {
        guard let context = context else { return .use(handle.transportURL, switched: nil) }
        let scope = handle.addon.debridScope ?? .both
        switch context.service {
        case .torbox:
            // TorBox: every addon exactly as installed.
            return scope == .realDebrid ? .skip : .use(handle.transportURL, switched: nil)
        case .realDebrid:
            switch scope {
            case .torbox: return .skip
            case .realDebrid: return .use(handle.transportURL, switched: nil)
            case .both:
                guard let key = context.realDebridKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                      let host = handle.transportURL.host, let known = AddonDebridRouting.kind(host: host) else {
                    return .use(handle.transportURL, switched: nil)
                }
                guard let url = rewrite(handle.transportURL, kind: known, realDebridKey: key) else { return .unreadable(known) }
                return .use(url, switched: known)
            }
        }
    }

    public static func rewrite(_ url: URL, kind: Kind, realDebridKey: String) -> URL? {
        switch kind {
        case .torrentio: return rewriteTorrentio(url, key: realDebridKey)
        case .comet: return rewriteComet(url, key: realDebridKey)
        }
    }

    /// A source of a switched addon that is not ready on Real-Debrid (a "download to Real-Debrid" link, an uncached result or an
    /// error line), left out as a second guard behind the addon's own option.
    public static func isReadyOnRealDebrid(_ stream: AddonStream, kind: Kind) -> Bool {
        let name = stream.name ?? ""
        switch kind {
        case .torrentio:
            if name.contains("download]") { return false }
            if name.contains("RD error") { return false }
            return true
        case .comet:
            // ⬇ (not cached) and 🧲 (P2P), compared by scalar: the emoji may carry a variation selector.
            if name.unicodeScalars.contains(where: { $0.value == 0x2B07 || $0.value == 0x1F9F2 }) { return false }
            if name.contains("[RD U]") { return false }
            return true
        }
    }

    // MARK: Torrentio

    /// Torrentio keeps its options in the first part of the path, `key=value` pairs joined by `|`, lists by `,`
    /// (`/providers=yts,eztv|sort=quality|torbox=KEY/manifest.json`). Several debrid services can be set at once: every other one
    /// is taken out, so only Real-Debrid sources come back.
    static let torrentioDebridKeys: Set<String> = [
        "realdebrid", "premiumize", "alldebrid", "debridlink", "easydebrid", "offcloud", "torbox", "putio", "highway",
    ]

    static func rewriteTorrentio(_ url: URL, key: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = segments.last, last == "manifest.json" else { return nil }
        let hasConfig = segments.count >= 2
        let encodedConfig = hasConfig ? segments[segments.count - 2] : ""
        let config = encodedConfig.removingPercentEncoding ?? encodedConfig
        var pairs: [(String, String)] = []
        for part in config.split(separator: "|", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            // A part without `=` (the "lite" preset) is not an option Torrentio reads among others: it is left out.
            guard pieces.count == 2, let name = pieces.first, !name.isEmpty else { continue }
            pairs.append((name, pieces[1]))
        }
        pairs.removeAll { torrentioDebridKeys.contains($0.0.lowercased()) }
        // Only the sources already on Real-Debrid: no "download to Real-Debrid" links.
        if let index = pairs.firstIndex(where: { $0.0 == "debridoptions" }) {
            var options = pairs[index].1.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !options.contains("nodownloadlinks") { options.append("nodownloadlinks") }
            pairs[index].1 = options.joined(separator: ",")
        } else {
            pairs.append(("debridoptions", "nodownloadlinks"))
        }
        pairs.append(("realdebrid", key))
        let rebuilt = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/|?#%")
        guard let encoded = rebuilt.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        if hasConfig {
            segments[segments.count - 2] = encoded
        } else {
            segments.insert(encoded, at: segments.count - 1)
        }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        return components.url
    }

    // MARK: Comet

    /// Comet keeps its options as JSON in base64 (standard alphabet, with padding) in the part of the path before `manifest.json`.
    /// The debrid is `debridServices: [{service, apiKey}]` (and, in older versions, `debridService` / `debridApiKey`); `cachedOnly`
    /// leaves out what is not ready. The P2P results (`enableTorrent`) are switched off: they are not on Real-Debrid.
    static func rewriteComet(_ url: URL, key: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, segments[segments.count - 1] == "manifest.json" else { return nil }
        let encoded = segments[segments.count - 2]
        guard var config = decodeCometConfig(encoded) else { return nil }
        config["debridServices"] = [["service": "realdebrid", "apiKey": key]]
        config["debridService"] = "realdebrid"
        config["debridApiKey"] = key
        config["cachedOnly"] = true
        config["enableTorrent"] = false
        guard let replacement = encodeCometConfig(config) else { return nil }
        segments[segments.count - 2] = replacement
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        return components.url
    }

    static func decodeCometConfig(_ segment: String) -> [String: Any]? {
        var text = (segment.removingPercentEncoding ?? segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let object = try? JSONSerialization.jsonObject(with: data), let config = object as? [String: Any] else { return nil }
        return config
    }

    /// Base64 of the JSON. The characters that would give `/` or `+` in base64 (`?`, `>`, `~`, only ever inside strings) are written
    /// as JSON escapes, so the result is letters, digits and `=` only and is a clean path segment.
    static func encodeCometConfig(_ config: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              var json = String(data: data, encoding: .utf8) else { return nil }
        json = json.replacingOccurrences(of: "?", with: "\\u003f")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "~", with: "\\u007e")
            .replacingOccurrences(of: "\u{7F}", with: "\\u007f")
        let result = Data(json.utf8).base64EncodedString()
        guard !result.contains("/"), !result.contains("+") else { return nil }
        return result
    }
}
