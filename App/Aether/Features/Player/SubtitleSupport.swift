import Foundation
import AetherCore

// Decision logic for subtitles and audio in the player, kept apart from the view model so it can be unit-tested without an
// engine: which languages the viewer wants (settings first, then what they chose by hand during this session), which track
// or subtitle wins, how the rows of the Tracks sheet read, and how a subtitle file is downloaded and parsed.
// Nothing in this file touches UIKit, the player or the network layer directly.

// MARK: - Choices made by hand during one player session

/// What the viewer asked for about subtitles by hand.
enum SubtitleChoice: Equatable {
    /// Subtitles switched off.
    case off
    /// A language, as a stable code (`LanguageCodes.normalise`).
    case language(String)
}

/// Audio and subtitle choices the viewer made by hand in the current player session. They are applied to the next episode of
/// the same series instead of the defaults of the settings, and they are forgotten when the title changes or the player closes
/// (the value lives in the view model: nothing is written to disk).
struct SessionTrackMemory: Equatable {
    private(set) var metaID: String?
    private(set) var rememberedAudioLanguage: String?
    private(set) var rememberedSubtitle: SubtitleChoice?

    init() {}

    var isEmpty: Bool {
        return rememberedAudioLanguage == nil && rememberedSubtitle == nil
    }

    /// Remembers the language of an audio track picked by hand. A track without a usable language leaves the memory as it was.
    mutating func rememberAudio(language: String?, metaID: String) {
        adopt(metaID)
        guard let code = SessionTrackMemory.stableCode(language) else { return }
        rememberedAudioLanguage = code
    }

    mutating func rememberSubtitle(_ choice: SubtitleChoice, metaID: String) {
        adopt(metaID)
        rememberedSubtitle = choice
    }

    /// Audio language to prefer for this title, nil when the viewer chose nothing (or chose it for another title).
    func audioLanguageToApply(forMeta metaID: String) -> String? {
        if self.metaID != metaID { return nil }
        return rememberedAudioLanguage
    }

    func subtitleChoiceToApply(forMeta metaID: String) -> SubtitleChoice? {
        if self.metaID != metaID { return nil }
        return rememberedSubtitle
    }

    mutating func reset() {
        metaID = nil
        rememberedAudioLanguage = nil
        rememberedSubtitle = nil
    }

    /// A different title starts from a clean slate.
    private mutating func adopt(_ id: String) {
        if metaID != id {
            metaID = id
            rememberedAudioLanguage = nil
            rememberedSubtitle = nil
        }
    }

    /// Stable code for an engine or addon language; nil for blank text, "und" and "off".
    static func stableCode(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let code = LanguageCodes.normalise(trimmed)
        if code.isEmpty || code == "und" || code == "off" { return nil }
        return code
    }
}

// MARK: - Language wishes and automatic choices

/// A subtitle track the engine reports as part of the file.
struct EmbeddedSubtitleInfo: Equatable {
    var optionID: String
    var title: String
    var language: String?

    init(optionID: String, title: String, language: String? = nil) {
        self.optionID = optionID
        self.title = title
        self.language = language
    }
}

/// What the automatic selection decided at the start of a video.
enum AutomaticSubtitleDecision: Equatable {
    /// Switch on this embedded track (`EmbeddedSubtitleInfo.optionID`).
    case embedded(optionID: String)
    /// Download and show this addon subtitle.
    case addon(SubtitleCandidate)
    /// Not enough is known yet (the addons have not answered): ask again when they have.
    case wait
    /// Nothing matches the viewer's languages: no subtitle is switched on.
    case nothing
}

enum TrackPreferences {
    /// Stable codes in the given order, without blanks, "off" or repetitions. The inputs are languages already resolved from the
    /// settings (`SettingsStore.resolvedLanguage`, nil for "off") or taken from the session memory.
    static func orderedLanguages(_ wishes: [String?]) -> [String] {
        var result: [String] = []
        for wish in wishes {
            guard let raw = wish else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "off" { continue }
            let code = LanguageCodes.normalise(trimmed)
            if code.isEmpty || result.contains(code) { continue }
            result.append(code)
        }
        return result
    }

    // MARK: Audio

    /// Languages to try for the audio track: what the viewer picked by hand for this title, then the preferred language, then
    /// the secondary one. "off" settings arrive as nil.
    static func audioLanguages(remembered: String?, primary: String?, secondary: String?) -> [String] {
        return orderedLanguages([remembered, primary, secondary])
    }

    static func audioTrackMatches(_ track: EngineTrack, language: String) -> Bool {
        if let tag = track.language, !tag.isEmpty, LanguageCodes.matches(tag, language) { return true }
        return LanguageCodes.matches(track.title, language)
    }

    /// The track for the first language that has one; the earlier the language in the list, the higher its priority.
    static func pickAudio(languages: [String], tracks: [EngineTrack]) -> EngineTrack? {
        for language in languages {
            for track in tracks {
                if audioTrackMatches(track, language: language) { return track }
            }
        }
        return nil
    }

    /// What to remember when the viewer picks this audio track by hand.
    static func audioLanguageToRemember(for track: EngineTrack) -> String? {
        if let code = SessionTrackMemory.stableCode(track.language) { return code }
        return SessionTrackMemory.stableCode(track.title)
    }

    // MARK: Subtitles

    /// Languages that order the subtitle list (and the automatic choice): the language picked by hand for this title, then the
    /// preferred language, then the secondary one.
    static func subtitleRanking(remembered: SubtitleChoice?, primary: String?, secondary: String?) -> [String] {
        var first: String?
        if let choice = remembered, case .language(let code) = choice { first = code }
        return orderedLanguages([first, primary, secondary])
    }

    /// Languages the automatic selection may switch on. Empty when the viewer turned subtitles off by hand, and when both
    /// settings are "off".
    static func automaticSubtitleLanguages(remembered: SubtitleChoice?, primary: String?, secondary: String?) -> [String] {
        if let choice = remembered, choice == .off { return [] }
        return subtitleRanking(remembered: remembered, primary: primary, secondary: secondary)
    }

    /// Embedded subtitles that only translate foreign dialogue are never switched on automatically.
    static func looksForced(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("forzat") || lower.contains("forced")
    }

    static func embeddedMatch(_ tracks: [EmbeddedSubtitleInfo], language: String) -> EmbeddedSubtitleInfo? {
        for track in tracks {
            if looksForced(track.title) { continue }
            if let tag = track.language, !tag.isEmpty, LanguageCodes.matches(tag, language) { return track }
            if LanguageCodes.matches(track.title, language) { return track }
        }
        return nil
    }

    /// Embedded track in the first wished language, otherwise the best addon subtitle for that language
    /// (`SubtitleCatalog.preferred`), and only then the next language. While the addons have not answered (`listIsFinal` false)
    /// a language without an embedded track makes the answer `.wait`: an addon subtitle for it would beat any later language.
    static func decide(languages: [String], embedded: [EmbeddedSubtitleInfo], candidates: [SubtitleCandidate],
                       listIsFinal: Bool) -> AutomaticSubtitleDecision {
        for language in languages {
            if let track = embeddedMatch(embedded, language: language) {
                return .embedded(optionID: track.optionID)
            }
            let preferences = SubtitlePreferences(languages: [language], preferHearingImpaired: false)
            if let candidate = SubtitleCatalog.preferred(in: candidates, preferences: preferences) {
                return .addon(candidate)
            }
            if !listIsFinal { return .wait }
        }
        return .nothing
    }
}

// MARK: - What the Tracks sheet shows

enum SubtitleListPhase: Equatable {
    /// The addons have not answered yet.
    case loading
    case ready
}

/// Why the list of addon subtitles is empty, when it is.
enum SubtitleEmptyState: Equatable {
    /// No installed, enabled addon can serve subtitles for this title.
    case noProvider
    /// At least one addon was asked and sent nothing.
    case nothingFound

    static func resolve(phase: SubtitleListPhase, hasProvider: Bool, externalCount: Int) -> SubtitleEmptyState? {
        if phase == .loading || externalCount > 0 { return nil }
        return hasProvider ? .nothingFound : .noProvider
    }
}

/// How one subtitle reads in a language group of the sheet.
struct SubtitleRowText: Equatable {
    var title: String
    var detail: String?
    var accessibilityLabel: String

    static let unspecifiedLanguage = "Lingua non specificata"

    /// Name of a language group (the header and the filter chip).
    static func groupName(_ group: SubtitleLanguageGroup) -> String {
        if group.language == "und" { return unspecifiedLanguage }
        return group.name
    }

    /// One row per candidate of the group, in order. Entries that would read the same get a number ("Italiano 1", "Italiano 2").
    static func rows(for group: SubtitleLanguageGroup) -> [SubtitleRowText] {
        var totals: [String: Int] = [:]
        for candidate in group.candidates {
            let key = baseTitle(of: candidate).lowercased()
            totals[key, default: 0] += 1
        }
        var counters: [String: Int] = [:]
        var rows: [SubtitleRowText] = []
        for candidate in group.candidates {
            let key = baseTitle(of: candidate).lowercased()
            counters[key, default: 0] += 1
            var number: Int?
            if (totals[key] ?? 0) > 1 { number = counters[key] }
            rows.append(make(candidate, number: number))
        }
        return rows
    }

    static func languageName(of candidate: SubtitleCandidate) -> String {
        if candidate.language == "und" { return unspecifiedLanguage }
        return candidate.languageName
    }

    private static func baseTitle(of candidate: SubtitleCandidate) -> String {
        let label = candidate.subtitle.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty { return label }
        return languageName(of: candidate)
    }

    static func make(_ candidate: SubtitleCandidate, number: Int?) -> SubtitleRowText {
        var title = baseTitle(of: candidate)
        if let number = number { title += " \(number)" }
        var notes: [String] = []
        if candidate.isHearingImpaired { notes.append("Non udenti") }
        if candidate.isForced { notes.append("Forzati") }
        if let addon = candidate.addonName, !addon.isEmpty { notes.append(addon) }
        var detail: String?
        if !notes.isEmpty { detail = notes.joined(separator: " · ") }

        var spoken: [String] = []
        let language = languageName(of: candidate)
        if !title.lowercased().contains(language.lowercased()) { spoken.append(language) }
        spoken.append(title)
        spoken.append(contentsOf: notes)
        return SubtitleRowText(title: title, detail: detail, accessibilityLabel: spoken.joined(separator: ", "))
    }
}

extension SubtitleOption {
    /// Identifier of the option built for an addon subtitle: stable across refreshes of the list (the URL is unique).
    static func optionID(for candidate: SubtitleCandidate) -> String {
        return "addon-" + candidate.url
    }

    static func addon(_ candidate: SubtitleCandidate) -> SubtitleOption {
        let text = SubtitleRowText.make(candidate, number: nil)
        return SubtitleOption(id: optionID(for: candidate),
                              title: text.title,
                              detail: text.detail,
                              language: candidate.subtitle.lang,
                              kind: .addon(candidate.subtitle),
                              languageCode: SessionTrackMemory.stableCode(candidate.language),
                              encodingHint: candidate.encodingHint)
    }
}

// MARK: - Subtitle files

/// Downloads a subtitle from an addon and turns it into cues. The HTTP client is the app's own (network policy, size cap), so a
/// test can hand in a stub. Parsing runs off the main thread: a large file must not stall the player controls.
struct SubtitleFileLoader: Sendable {
    let http: HTTPClient
    let timeout: TimeInterval

    init(http: HTTPClient, timeout: TimeInterval = 15) {
        self.http = http
        self.timeout = timeout
    }

    func download(url: URL) async throws -> Data {
        let request = HTTPRequest(url: url, timeout: timeout, maxBytes: HTTPLimits.subtitle, purpose: .addonRequest)
        let response = try await http.send(request)
        guard response.isSuccess else { throw AddonError.http(status: response.statusCode) }
        return response.data
    }

    func load(url: URL, languageHint: String?, encodingHint: String?) async throws -> [SubtitleCue] {
        let data = try await download(url: url)
        return try await SubtitleFileLoader.parse(data, languageHint: languageHint, encodingHint: encodingHint)
    }

    static func parse(_ data: Data, languageHint: String?, encodingHint: String?) async throws -> [SubtitleCue] {
        let work = Task.detached(priority: .userInitiated) { () throws -> [SubtitleCue] in
            return try SubtitleParser.parse(data, languageHint: languageHint, encodingHint: encodingHint)
        }
        return try await work.value
    }

    /// Message for the viewer when a subtitle could not be used.
    static func message(for error: Error) -> String {
        if let subtitleError = error as? SubtitleError { return subtitleError.message }
        if let addonError = error as? AddonError { return "Sottotitoli non scaricabili: \(addonError.message)" }
        return "Sottotitoli non utilizzabili: \(error.localizedDescription)"
    }
}

// MARK: - Local hash of the video

enum SubtitleHashPlan {
    /// Whether the app should compute the OpenSubtitles hash of this stream itself. Never for downloads (no network source),
    /// for anything that is not one plain http(s) file (torrents, YouTube, pages, archives), for HLS / DASH / Smooth Streaming,
    /// or when the stream already announces both `videoHash` and `videoSize`. `http://` to a public host passes this check on
    /// purpose: `SubtitleHashProbe` refuses it itself (App Transport Security would block the request).
    static func shouldProbe(stream: AddonStream?, isDownload: Bool) -> Bool {
        if isDownload { return false }
        guard let stream = stream else { return false }
        guard case .url(let raw) = stream.source else { return false }
        let announced = SubtitleVideoParams.resolve(stream: stream)
        if announced.hash != nil && announced.size != nil { return false }
        guard let url = URL.lenient(raw), let scheme = url.scheme?.lowercased() else { return false }
        if scheme != "http" && scheme != "https" { return false }
        if isAdaptive(raw) { return false }
        return true
    }

    /// HLS (`.m3u8`), DASH (`.mpd`) and Smooth Streaming (`.ism/manifest`) are recognised from the URL alone.
    static func isAdaptive(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        let markers: [String] = [".m3u8", ".mpd", ".ism/manifest", ".isml/manifest"]
        for marker in markers where lower.contains(marker) { return true }
        // A plain `.m3u` playlist, with or without a query string.
        var path = lower
        if let query = path.firstIndex(of: "?") { path = String(path[path.startIndex..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[path.startIndex..<fragment]) }
        return path.hasSuffix(".m3u")
    }
}

// MARK: - Addons that serve subtitles

enum SubtitleAddonSupport {
    /// True when the manifest declares `subtitles` for the type and for the id prefix (the resource's own prefixes, otherwise the
    /// manifest's; no prefixes at all means every id). Same rule as `AddonService.subtitles`.
    static func canServe(_ manifest: AddonManifest, type: String, videoID: String) -> Bool {
        let path = ResourcePath(resource: ResourceName.subtitles, type: type, id: videoID)
        guard manifest.supports(path) else { return false }
        guard let resource = manifest.resource(named: ResourceName.subtitles) else { return false }
        let declared: [String]? = resource.idPrefixes ?? manifest.idPrefixes
        guard let prefixes = declared, !prefixes.isEmpty else { return true }
        return prefixes.contains(where: { (prefix: String) -> Bool in
            return videoID.hasPrefix(prefix)
        })
    }

    /// The enabled addons that will be asked for subtitles of this video.
    static func providers(in handles: [AddonHandle], type: String, videoID: String) -> [AddonHandle] {
        return handles.filter { (handle: AddonHandle) -> Bool in
            return canServe(handle.addon.manifest, type: type, videoID: videoID)
        }
    }
}

/// The optional subtitles addon offered in Addons → Consigliato. Nothing is installed without the viewer's confirmation.
enum RecommendedSubtitleAddon {
    /// Official Stremio addon, no account and no key (docs/research/api-probe-2026-10-20.md).
    static let manifestURL = URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!
    static let addonID = "org.stremio.opensubtitlesv3"
    static let name = "OpenSubtitles v3"

    static func isInstalled(in addons: [InstalledAddon]) -> Bool {
        return addons.contains(where: { (addon: InstalledAddon) -> Bool in
            return addon.manifest.id == addonID
        })
    }
}
