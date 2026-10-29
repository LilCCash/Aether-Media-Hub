import Foundation

/// Parsing / normalisation of the strings users paste or deep links deliver.
public enum AddonURL {
    public static let manifestSuffix = "/manifest.json"

    /// Turns user input into a canonical manifest URL.
    ///
    /// Accepts:
    /// * `https://host/path/manifest.json`
    /// * `stremio://host/path/manifest.json` (→ https, the documented deep-link form)
    /// * `https://host/path/configure` (the addon landing page → manifest)
    /// * `https://host/path` without `.json` (→ `/manifest.json` appended)
    ///
    /// Rejects schemes other than http/https/stremio, embedded credentials and missing hosts.
    /// The fragment is dropped; the query is kept (many addons keep their configuration there).
    public static func parseInstallInput(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") && text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if text.isEmpty { throw AddonError.invalidURL("l'indirizzo è vuoto") }
        if text.count > 4096 { throw AddonError.blockedURL(.tooLong) }

        let lower = text.lowercased()
        if lower.hasPrefix("stremio:///") {
            // stremio:///detail/... and friends are navigation links, not addon installs.
            throw AddonError.invalidURL("questo link Stremio non installa un addon")
        } else if lower.hasPrefix("stremio://") {
            text = "https://" + text.dropFirst("stremio://".count)
        } else if lower.hasPrefix("stremio:") {
            // stremio:///detail/... and friends are navigation links, not addon installs.
            throw AddonError.invalidURL("questo link Stremio non installa un addon")
        } else if !lower.contains("://") {
            // "javascript:…", "data:…", "mailto:…" are schemes, while "host:7000/path" is a bare host with a port.
            if let colon = text.firstIndex(of: ":"), colon != text.startIndex {
                let name = String(text[text.startIndex..<colon])
                let rest = text[text.index(after: colon)...]
                let looksLikePort = rest.first.map { $0.isNumber } ?? false
                let validSchemeName = (name.first?.isLetter ?? false)
                    && name.allSatisfy { $0.isLetter || $0.isNumber || "+.-".contains($0) }
                if validSchemeName && !looksLikePort {
                    throw AddonError.blockedURL(.scheme(name.lowercased()))
                }
            }
            // Bare "host/path/manifest.json" pasted without scheme.
            text = "https://" + text
        }

        guard var components = URLComponents(string: text) else {
            throw AddonError.invalidURL("formato non riconosciuto")
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw AddonError.invalidURL("manca lo schema")
        }
        guard scheme == "http" || scheme == "https" else {
            throw AddonError.blockedURL(.scheme(scheme))
        }
        if components.user != nil || components.password != nil {
            throw AddonError.blockedURL(.credentialsInURL)
        }
        guard let host = components.host, !host.isEmpty else {
            throw AddonError.blockedURL(.emptyHost)
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if path.lowercased().hasSuffix(manifestSuffix) {
            // already canonical
        } else if path.lowercased().hasSuffix("/configure") {
            path = String(path.dropLast("/configure".count)) + manifestSuffix
        } else if path.lowercased().hasSuffix(".json") {
            throw AddonError.invalidURL("l'URL deve terminare con /manifest.json")
        } else {
            if !path.hasSuffix("/") { path += "/" }
            path += "manifest.json"
        }
        components.percentEncodedPath = path

        guard let url = components.url else { throw AddonError.invalidURL("formato non riconosciuto") }
        return url
    }

    /// A string that identifies the addon endpoint independent of host case and fragment; used for duplicate detection.
    public static func canonicalKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? url.absoluteString
    }

    /// Non-secret label safe for UI and logs: `host[:port]`. Addon URLs often embed API keys in path/query.
    public static func displayHost(_ url: URL) -> String {
        guard let host = url.host else { return "—" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// Parses links the app handles on launch: `stremio://…/manifest.json`, `aether://addon?url=…`, `aether://install/<url>`.
    public static func installURL(fromDeepLink link: URL) -> URL? {
        guard let scheme = link.scheme?.lowercased() else { return nil }
        if scheme == "stremio" {
            return try? parseInstallInput(link.absoluteString)
        }
        if scheme == "aether" {
            let host = link.host?.lowercased() ?? ""
            if host == "addon" || host == "install" {
                if let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
                   let value = components.queryItems?.first(where: { $0.name == "url" })?.value {
                    return try? parseInstallInput(value)
                }
            }
        }
        return nil
    }
}

/// Builds `{base}/{resource}/{type}/{id}[/{extra}].json` exactly like stremio-core's HTTP transport.
public enum ResourceURLBuilder {
    public static func encodeExtra(_ extra: [ExtraValue]) -> String {
        return extra
            .map { "\(URIComponent.encode($0.name))=\(URIComponent.encode($0.value))" }
            .joined(separator: "&")
    }

    /// The resource path component for a request (without leading slash or base).
    public static func relativePath(for path: ResourcePath) -> String {
        var result = "\(URIComponent.encode(path.resource))/\(URIComponent.encode(path.type))/\(URIComponent.encode(path.id))"
        if !path.extra.isEmpty {
            result += "/" + encodeExtra(path.extra)
        }
        return result + ".json"
    }

    /// Replaces the trailing `/manifest.json` of the transport URL; the query of the manifest URL is preserved.
    public static func url(transport: URL, path: ResourcePath) -> URL? {
        guard var components = URLComponents(url: transport, resolvingAgainstBaseURL: false) else { return nil }
        let currentPath = components.percentEncodedPath
        guard currentPath.lowercased().hasSuffix(AddonURL.manifestSuffix) else { return nil }
        let base = String(currentPath.dropLast(AddonURL.manifestSuffix.count))
        components.percentEncodedPath = base + "/" + relativePath(for: path)
        components.fragment = nil
        return components.url
    }
}
