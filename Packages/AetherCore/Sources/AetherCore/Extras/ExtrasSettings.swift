import Foundation

/// Switches for the optional features added in November 2026. Each one can be turned off in Settings.
public struct ExtrasSettings: Codable, Equatable, Sendable {
    /// Look at the SideStore source once in a while and tell when a newer build exists.
    public var checkUpdates: Bool = true
    /// Show the notes of the build once after an update.
    public var showWhatsNew: Bool = true
    /// The build whose notes were last shown (state, not a choice).
    public var lastSeenBuild: Int = 0
    /// Near the end of an episode, ask for the next one's link ahead of time (and open the connection).
    public var prefetchNextLink: Bool = true
    /// Local notification on the day a new episode of a followed series comes out (needs Trakt).
    public var episodeNotifications: Bool = false
    /// Hour (0...23) at which the notification of the day arrives.
    public var episodeNotificationHour: Int = 18
    /// Offer to translate a subtitle on the device when there is none in the viewer's language.
    public var translateSubtitles: Bool = false
    /// Tint the title page and the controls with the colours of the poster.
    public var posterTint: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case checkUpdates, showWhatsNew, lastSeenBuild, prefetchNextLink, episodeNotifications, episodeNotificationHour, translateSubtitles, posterTint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkUpdates = c.value(.checkUpdates, default: true)
        showWhatsNew = c.value(.showWhatsNew, default: true)
        lastSeenBuild = c.value(.lastSeenBuild, default: 0)
        prefetchNextLink = c.value(.prefetchNextLink, default: true)
        episodeNotifications = c.value(.episodeNotifications, default: false)
        episodeNotificationHour = min(23, max(0, c.value(.episodeNotificationHour, default: 18) as Int))
        translateSubtitles = c.value(.translateSubtitles, default: false)
        posterTint = c.value(.posterTint, default: true)
    }
}

// MARK: Updates (SideStore source)

/// A build listed in the SideStore source (`source.json`, written by `Scripts/publish_devbuild.py`).
public struct DevbuildRelease: Equatable, Sendable {
    public var version: String
    public var build: Int
    public var date: String?
    public var downloadURL: URL
    public var notes: String
}

public enum DevbuildFeed {
    public static let sourceURL = URL(string: "https://github.com/LilCCash/Aether-Media-Hub/releases/download/devbuilds/source.json")!
    /// The IPA is only taken from here: a source that points elsewhere is ignored.
    static let allowedHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    /// The newest build of the first app of the source, or nil when the file is not what is expected.
    public static func latest(from data: Data) -> DevbuildRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (root["apps"] as? [[String: Any]])?.first,
              let versions = app["versions"] as? [[String: Any]] else { return nil }
        let releases = versions.compactMap { (entry: [String: Any]) -> DevbuildRelease? in
            guard let build = Int("\(entry["buildVersion"] ?? "")"),
                  let text = entry["downloadURL"] as? String, let url = URL(string: text),
                  url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), allowedHosts.contains(host) else { return nil }
            return DevbuildRelease(version: entry["version"] as? String ?? "", build: build, date: entry["date"] as? String,
                                   downloadURL: url, notes: entry["localizedDescription"] as? String ?? "")
        }
        return releases.max { $0.build < $1.build }
    }

    public static func isNewer(_ release: DevbuildRelease, than installedBuild: Int) -> Bool {
        return installedBuild > 0 && release.build > installedBuild
    }

    /// SideStore's own address to install an IPA (same pattern as AltStore's `altstore://install?url=`; not verified on a device).
    public static func sideStoreInstallURL(for ipa: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return components.url
    }

    /// The notes written for a build, as plain list lines (what the sheet shows).
    public static func noteLines(_ text: String) -> [String] {
        return text.split(whereSeparator: { $0 == "\n" }).map { line -> String in
            var item = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "• "] where item.hasPrefix(prefix) { item = String(item.dropFirst(prefix.count)) }
            return item
        }.filter { !$0.isEmpty }
    }
}

// MARK: New-episode notifications

public struct EpisodeAlert: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var fire: Date
}

public enum EpisodeAlertPlanner {
    /// One notification per upcoming episode of the viewer's series, on the day it comes out at `hour` (or when it airs, if that is later
    /// the same day). Past episodes are skipped. At most `limit` (iOS keeps 64 pending notifications per app).
    public static func plan(_ items: [TraktTitle], now: Date, hour: Int, limit: Int = 40, calendar: Calendar = .current) -> [EpisodeAlert] {
        var seen = Set<String>()
        var alerts: [EpisodeAlert] = []
        for item in items {
            guard let text = item.firstAired, let aired = parse(text), aired > now,
                  let season = item.season, let episode = item.episode else { continue }
            let key = "\(item.imdb ?? item.title)-\(season)-\(episode)"
            guard seen.insert(key).inserted else { continue }
            let day = calendar.startOfDay(for: aired)
            var fire = calendar.date(bySettingHour: min(23, max(0, hour)), minute: 0, second: 0, of: day) ?? aired
            if fire < now { fire = aired }                    // the day's hour has passed: tell at the airing time
            if fire < now { continue }
            let label = String(format: "S%02dE%02d", season, episode)
            let body = [label, item.episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") + " esce oggi."
            alerts.append(EpisodeAlert(id: "aether.ep.\(key)", title: item.title, body: body, fire: fire))
        }
        return Array(alerts.sorted { $0.fire < $1.fire }.prefix(max(0, limit)))
    }

    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: Poster colours

public struct PosterColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
}

public struct PosterPalette: Equatable, Sendable {
    /// The colour that dominates the picture.
    public var base: PosterColor
    /// A dark version, for backgrounds behind white text.
    public var backdrop: PosterColor
    /// A bright, saturated version, for buttons and highlights.
    public var accent: PosterColor
}

public enum PosterPaletteExtractor {
    /// `pixels`: RGBA bytes of a small copy of the poster (about 24 × 36). Dull, near-black and near-white pixels count little:
    /// they are what posters have around the picture, not what they look like.
    public static func palette(rgba pixels: [UInt8]) -> PosterPalette? {
        guard pixels.count >= 4 else { return nil }
        var weightSum = 0.0, r = 0.0, g = 0.0, b = 0.0
        var plain = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        var index = 0
        while index + 3 < pixels.count {
            let alpha = Double(pixels[index + 3]) / 255
            let pr = Double(pixels[index]) / 255, pg = Double(pixels[index + 1]) / 255, pb = Double(pixels[index + 2]) / 255
            index += 4
            guard alpha > 0.5 else { continue }
            plain.r += pr; plain.g += pg; plain.b += pb; plain.n += 1
            let high = max(pr, pg, pb), low = min(pr, pg, pb)
            let saturation = high == 0 ? 0 : (high - low) / high
            let weight = saturation * saturation * high * (high > 0.12 && low < 0.92 ? 1 : 0.05)
            r += pr * weight; g += pg * weight; b += pb * weight; weightSum += weight
        }
        guard plain.n > 0 else { return nil }
        let base: PosterColor
        if weightSum > 0.0001 {
            base = PosterColor(red: r / weightSum, green: g / weightSum, blue: b / weightSum)
        } else {
            base = PosterColor(red: plain.r / plain.n, green: plain.g / plain.n, blue: plain.b / plain.n)
        }
        return PosterPalette(base: base, backdrop: scaled(base, brightness: 0.28), accent: scaled(base, brightness: 0.85, minSaturation: 0.45))
    }

    /// The same hue at the given brightness (0...1); saturation is raised to `minSaturation` when it is lower.
    static func scaled(_ color: PosterColor, brightness: Double, minSaturation: Double = 0) -> PosterColor {
        let high = max(color.red, color.green, color.blue), low = min(color.red, color.green, color.blue)
        guard high > 0 else { return PosterColor(red: brightness, green: brightness, blue: brightness) }
        var saturation = (high - low) / high
        saturation = max(saturation, minSaturation)
        // Rebuild from hue: keep the ratio of the channels, then set the saturation and the brightness.
        let channels = [color.red, color.green, color.blue].map { channel -> Double in
            let normalised = channel / high                       // 1 for the strongest channel
            let desaturated = 1 - saturation * (1 - normalised)    // pull the weaker channels toward the strongest
            return min(1, max(0, desaturated * brightness))
        }
        return PosterColor(red: channels[0], green: channels[1], blue: channels[2])
    }
}

// MARK: Subtitle translation

public enum SubtitleTranslationPlan {
    /// The indices of the cues grouped so that no group has more than `maxItems` cues or `maxCharacters` characters.
    public static func batches(for cues: [SubtitleCue], maxItems: Int = 40, maxCharacters: Int = 3000) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        var size = 0
        for (index, cue) in cues.enumerated() {
            let length = cue.text.count
            if !current.isEmpty && (current.count >= maxItems || size + length > maxCharacters) {
                result.append(current)
                current = []
                size = 0
            }
            current.append(index)
            size += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The text of a cue without styling tags (`<i>`, `{\an8}`), which a translator would garble.
    public static func plainText(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "{\\"), let close = result.range(of: "}", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        while let open = result.range(of: "<"), let close = result.range(of: ">", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cues with the translated text where there is one (the others stay as they are).
    public static func apply(_ translations: [Int: String], to cues: [SubtitleCue]) -> [SubtitleCue] {
        return cues.enumerated().map { (index: Int, cue: SubtitleCue) -> SubtitleCue in
            guard let text = translations[index], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cue }
            return SubtitleCue(start: cue.start, end: cue.end, text: text)
        }
    }

    /// Translation is offered when the subtitle is not already in the viewer's language.
    public static func shouldOffer(subtitleLanguage: String?, target: String) -> Bool {
        guard let language = subtitleLanguage?.lowercased(), !language.isEmpty else { return true }
        return !language.hasPrefix(target.lowercased())
    }
}
