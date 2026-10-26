import Foundation

// All settings are plain values with defaults. Decoding is lenient: an unknown/missing/invalid key falls back to its
// default, so adding a setting never invalidates a stored file or a backup made by another version.

public enum ThemeMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: return "Automatico"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }
}

public enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case aurora, ember, jade, rose, sky, gold

    public var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .ember: return "Brace"
        case .jade: return "Giada"
        case .rose: return "Rosa"
        case .sky: return "Cielo"
        case .gold: return "Oro"
        }
    }
}

public enum PosterSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: return "Piccola"
        case .medium: return "Media"
        case .large: return "Grande"
        }
    }

    /// Poster card width in points for horizontal rows.
    public var rowWidth: Double {
        switch self {
        case .small: return 104
        case .medium: return 128
        case .large: return 156
        }
    }

    /// Width in points of a wide (16:9) card. `medium` is the width "Continua a guardare" has always had.
    public var landscapeWidth: Double {
        switch self {
        case .small: return 200
        case .medium: return 240
        case .large: return 290
        }
    }
}

public enum CatalogDensity: String, Codable, CaseIterable, Sendable {
    case compact, comfortable

    public var title: String {
        switch self {
        case .compact: return "Compatta"
        case .comfortable: return "Comoda"
        }
    }
}

public struct HomeSectionConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var isVisible: Bool
    /// How the section's cards look. `nil` = the section's own default (see `HomeCardStyle.defaultStyle(for:)`).
    public var style: HomeCardStyle?
    /// Card size. `nil` = follow the general poster size of the appearance settings.
    public var size: PosterSize?

    public init(id: String, isVisible: Bool = true, style: HomeCardStyle? = nil, size: PosterSize? = nil) {
        self.id = id
        self.isVisible = isVisible
        self.style = style
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case id, isVisible, style, size
    }

    /// Hand-written on purpose: a synthesized decoder would reject every section stored by 1.0 (no `style`, `size`), the lossy
    /// array around it would drop them all and the viewer's order and hidden sections would silently reset.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        isVisible = c.value(.isVisible, default: true)
        style = c.lenient(HomeCardStyle.self, forKey: .style)
        size = c.lenient(PosterSize.self, forKey: .size)
    }

    /// The style actually drawn: the chosen one if this section offers it, otherwise the section's default.
    public var effectiveStyle: HomeCardStyle? {
        let allowed = HomeCardStyle.allowed(for: id)
        if let style = style, allowed.contains(style) { return style }
        return allowed.first
    }

    /// The size actually drawn. "Auto" follows the general poster size, except for the two sections whose cards were a fixed size
    /// in 1.0 (Continue Watching and Next Up, 240 pt wide): they stay at medium so a viewer who chose another general poster
    /// size does not see them change by themselves.
    public func effectiveSize(general: PosterSize) -> PosterSize {
        if let size = size { return size }
        switch id {
        case HomeSectionConfig.continueWatching, HomeSectionConfig.nextUp: return .medium
        default: return general
        }
    }

    public static let hero = "hero"
    public static let continueWatching = "continue"
    public static let nextUp = "nextUp"
    public static let watchlist = "watchlist"
    public static let catalogs = "catalogs"

    public static let defaultOrder: [HomeSectionConfig] = [
        HomeSectionConfig(id: hero), HomeSectionConfig(id: continueWatching), HomeSectionConfig(id: nextUp),
        HomeSectionConfig(id: watchlist), HomeSectionConfig(id: catalogs)
    ]

    public static func title(for id: String) -> String {
        switch id {
        case hero: return "In evidenza"
        case continueWatching: return "Continua a guardare"
        case nextUp: return "Prossimi episodi"
        case watchlist: return "Watchlist"
        case catalogs: return "Cataloghi degli addon"
        default: return id
        }
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var theme: ThemeMode = .system
    public var accent: AccentChoice = .aurora
    /// Optional custom accent in #RRGGBB; nil keeps the selected preset.
    public var customAccentHex: String? = nil
    // 1.5
    /// Optional custom background colour in #RRGGBB; nil keeps the palette's own.
    public var customBackgroundHex: String? = nil
    /// How strong the coloured washes of the background are (0 = none, 1 = as designed).
    public var backdropIntensity: Double = 1
    /// The star badge with the rating on the posters.
    public var showPosterRatings: Bool = true
    /// Dynamic Cinematic UI: the whole app takes its atmosphere from the film being looked at.
    public var dynamicCinematic: Bool = false
    /// Cinematic: tint the background with the colours of the film's artwork.
    public var cinematicMood: Bool = true
    /// Cinematic: slow zoom of the artwork and a soft fade when a page opens (off with Reduce Motion / animations off).
    public var cinematicMotion: Bool = true
    /// True black background (OLED), with the washes toned down and text kept at full contrast.
    public var amoled: Bool = false
    /// The coloured washes of the background (also in the cinematic mode); off = a calm plain background.
    public var showHalos: Bool = true
    public var posterSize: PosterSize = .medium
    public var density: CatalogDensity = .comfortable
    public var animationsEnabled: Bool = true
    public var reduceVisualEffects: Bool = false
    public var homeSections: [HomeSectionConfig] = HomeSectionConfig.defaultOrder
    // 1.1
    public var heroStyle: HeroStyle = .card
    /// The featured carousel turns pages by itself (still subject to Reduce Motion and the animations switch).
    public var heroAutoScroll: Bool = true
    public var palette: AppPalette = .aether
    public var backdrop: BackdropStyle = .aurora
    public var cardChrome: CardChrome = .standard
    public var cornerStyle: CornerStyle = .standard
    public var titleFont: TitleFont = .rounded
    public var greetingEnabled: Bool = false
    /// Shown in the greeting. Stored in the settings backup like everything else, unencrypted.
    public var greetingName: String = ""
    /// Raw ids of the hidden extras found so far (`AppSecret`).
    public var unlockedSecrets: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case customBackgroundHex, backdropIntensity, showPosterRatings, dynamicCinematic, cinematicMood, cinematicMotion, amoled, showHalos
        case theme, accent, customAccentHex, posterSize, density, animationsEnabled, reduceVisualEffects, homeSections
        case heroStyle, heroAutoScroll, palette, backdrop, cardChrome, cornerStyle, titleFont
        case greetingEnabled, greetingName, unlockedSecrets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = c.value(.theme, default: .system)
        accent = c.value(.accent, default: .aurora)
        let customAccent: String? = c.lenient(String.self, forKey: .customAccentHex)
        customAccentHex = customAccent.flatMap { value in
            let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil else { return nil }
            return hex
        }
        let customBackground: String? = c.lenient(String.self, forKey: .customBackgroundHex)
        customBackgroundHex = customBackground.flatMap { value in
            let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil else { return nil }
            return hex
        }
        let intensity: Double = c.value(.backdropIntensity, default: 1)
        backdropIntensity = intensity.isFinite ? min(1, max(0, intensity)) : 1
        showPosterRatings = c.value(.showPosterRatings, default: true)
        dynamicCinematic = c.value(.dynamicCinematic, default: false)
        cinematicMood = c.value(.cinematicMood, default: true)
        cinematicMotion = c.value(.cinematicMotion, default: true)
        amoled = c.value(.amoled, default: false)
        showHalos = c.value(.showHalos, default: true)
        posterSize = c.value(.posterSize, default: .medium)
        density = c.value(.density, default: .comfortable)
        animationsEnabled = c.value(.animationsEnabled, default: true)
        reduceVisualEffects = c.value(.reduceVisualEffects, default: false)
        let stored = c.lossyArray(HomeSectionConfig.self, forKey: .homeSections)
        homeSections = AppearanceSettings.normalise(sections: stored)
        heroStyle = c.value(.heroStyle, default: .card)
        heroAutoScroll = c.value(.heroAutoScroll, default: true)
        backdrop = c.value(.backdrop, default: .aurora)
        cardChrome = c.value(.cardChrome, default: .standard)
        cornerStyle = c.value(.cornerStyle, default: .standard)
        titleFont = c.value(.titleFont, default: .rounded)
        greetingEnabled = c.value(.greetingEnabled, default: false)
        let name: String = c.value(.greetingName, default: "")
        greetingName = Greeting.sanitizedName(name)
        unlockedSecrets = AppearanceSettings.dedupe(c.stringList(.unlockedSecrets))
        // The secrets are read first: a palette that needs one is only honoured if it is unlocked.
        let chosen: AppPalette = c.value(.palette, default: .aether)
        palette = isAvailable(chosen) ? chosen : .aether
    }

    // MARK: Secrets

    public func isUnlocked(_ secret: AppSecret) -> Bool {
        return unlockedSecrets.contains(secret.rawValue)
    }

    /// Whether `palette` can be chosen now.
    public func isAvailable(_ palette: AppPalette) -> Bool {
        guard let secret = palette.requiredSecret else { return true }
        return isUnlocked(secret)
    }

    /// Returns true only the first time.
    @discardableResult
    public mutating func unlock(_ secret: AppSecret) -> Bool {
        guard !isUnlocked(secret) else { return false }
        unlockedSecrets.append(secret.rawValue)
        return true
    }

    private static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: Sections

    /// The stored configuration of one section (the default when it is not stored, which `normalise` prevents).
    public func section(_ id: String) -> HomeSectionConfig {
        return homeSections.first(where: { $0.id == id }) ?? HomeSectionConfig(id: id)
    }

    /// Keeps known sections, preserves stored order/visibility, appends any new section at the end.
    public static func normalise(sections stored: [HomeSectionConfig]) -> [HomeSectionConfig] {
        let known = Set(HomeSectionConfig.defaultOrder.map { $0.id })
        var result: [HomeSectionConfig] = []
        var seen = Set<String>()
        for var section in stored where known.contains(section.id) && seen.insert(section.id).inserted {
            if let style = section.style, !HomeCardStyle.allowed(for: section.id).contains(style) { section.style = nil }
            result.append(section)
        }
        for section in HomeSectionConfig.defaultOrder where !seen.contains(section.id) {
            result.append(section)
        }
        return result
    }
}

public enum VideoQualityCap: String, Codable, CaseIterable, Sendable {
    case auto, p2160, p1080, p720

    public var title: String {
        switch self {
        case .auto: return "Massima disponibile"
        case .p2160: return "Fino a 4K"
        case .p1080: return "Fino a 1080p"
        case .p720: return "Fino a 720p"
        }
    }

    public var maxHeight: Int {
        switch self {
        case .auto: return Int.max
        case .p2160: return 2160
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}

public enum PlayerEngineChoice: String, Codable, CaseIterable, Sendable {
    case automatic, avPlayer, mpv

    public var title: String {
        switch self {
        case .automatic: return "Automatico (consigliato)"
        case .avPlayer: return "AVPlayer (Apple)"
        case .mpv: return "MPV (libmpv)"
        }
    }
}

/// How HDR sources are sent to the screen by the MPV engine. AVPlayer follows the system and has no such switch.
public enum HDROutputMode: String, Codable, CaseIterable, Sendable {
    case auto, sdr

    public var title: String {
        switch self {
        case .auto: return "Automatico (HDR se lo schermo lo mostra)"
        case .sdr: return "Sempre SDR (tone mapping)"
        }
    }
}

/// Tone-mapping curves of mpv/libplacebo used when HDR has to be reduced (names are mpv's `--tone-mapping` values).
public enum ToneMappingChoice: String, Codable, CaseIterable, Sendable {
    case auto, bt2390, spline, mobius, reinhard, hable

    public var title: String {
        switch self {
        case .auto: return "Automatico"
        case .bt2390: return "BT.2390"
        case .spline: return "Spline"
        case .mobius: return "Mobius"
        case .reinhard: return "Reinhard"
        case .hable: return "Hable"
        }
    }

    public var mpvValue: String {
        switch self {
        case .auto: return "auto"
        case .bt2390: return "bt.2390"
        case .spline: return "spline"
        case .mobius: return "mobius"
        case .reinhard: return "reinhard"
        case .hable: return "hable"
        }
    }
}

/// Video output options. Items marked "MPV" only act on the MPV engine; the buffer applies to both engines.
public struct VideoOutputSettings: Codable, Equatable, Sendable {
    public var hdrMode: HDROutputMode = .auto
    public var toneMapping: ToneMappingChoice = .auto
    public var computeHDRPeak: Bool = true
    public var hardwareDecoding: Bool = true
    public var deband: Bool = false
    /// -100...100, mpv's picture controls (0 = untouched).
    public var brightness: Int = 0
    public var contrast: Int = 0
    public var saturation: Int = 0
    public var gamma: Int = 0
    /// Forward buffer in seconds; 0 lets the engine decide.
    public var bufferSeconds: Int = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hdrMode, toneMapping, computeHDRPeak, hardwareDecoding, deband, brightness, contrast, saturation, gamma, bufferSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hdrMode = c.value(.hdrMode, default: .auto)
        toneMapping = c.value(.toneMapping, default: .auto)
        computeHDRPeak = c.value(.computeHDRPeak, default: true)
        hardwareDecoding = c.value(.hardwareDecoding, default: true)
        deband = c.value(.deband, default: false)
        brightness = min(100, max(-100, c.value(.brightness, default: 0)))
        contrast = min(100, max(-100, c.value(.contrast, default: 0)))
        saturation = min(100, max(-100, c.value(.saturation, default: 0)))
        gamma = min(100, max(-100, c.value(.gamma, default: 0)))
        let buffer: Int = c.value(.bufferSeconds, default: 0)
        bufferSeconds = buffer <= 0 ? 0 : min(120, max(5, buffer))
    }
}

/// Colours are `#RRGGBB` strings so the model stays UI-framework free.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// 50...200 (% of the default size).
    public var sizePercent: Double = 100
    public var textColor: String = "#FFFFFF"
    public var isBold: Bool = false
    public var outlineEnabled: Bool = true
    public var outlineColor: String = "#000000"
    public var backgroundColor: String = "#000000"
    /// 0...1
    public var backgroundOpacity: Double = 0
    /// Distance from the bottom edge as % of the video height (2...40).
    public var bottomOffsetPercent: Double = 8

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sizePercent, textColor, isBold, outlineEnabled, outlineColor, backgroundColor, backgroundOpacity, bottomOffsetPercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sizePercent = min(200, max(50, c.value(.sizePercent, default: 100.0)))
        textColor = c.value(.textColor, default: "#FFFFFF")
        isBold = c.value(.isBold, default: false)
        outlineEnabled = c.value(.outlineEnabled, default: true)
        outlineColor = c.value(.outlineColor, default: "#000000")
        backgroundColor = c.value(.backgroundColor, default: "#000000")
        backgroundOpacity = min(1, max(0, c.value(.backgroundOpacity, default: 0.0)))
        bottomOffsetPercent = min(40, max(2, c.value(.bottomOffsetPercent, default: 8.0)))
    }
}

public struct PlaybackSettings: Codable, Equatable, Sendable {
    public var engine: PlayerEngineChoice = .automatic
    public var autoResume: Bool = true
    public var resumeRewindSeconds: Int = 0
    public var skipBackSeconds: Int = 10
    public var skipForwardSeconds: Int = 10
    public var autoplayNextEpisode: Bool = true
    public var nextEpisodeCountdownSeconds: Int = 8
    /// "system" or an ISO 639-1/2 code.
    public var preferredAudioLanguage: String = "system"
    /// "off", "system" or a language code.
    public var preferredSubtitleLanguage: String = "off"
    public var subtitleStyle: SubtitleStyle = SubtitleStyle()
    public var subtitleDelaySeconds: Double = 0
    public var autoPictureInPicture: Bool = true
    public var allowBackgroundAudio: Bool = true
    /// Default sleep timer preset in minutes (0 = off).
    public var defaultSleepTimerMinutes: Int = 0
    public var qualityCap: VideoQualityCap = .auto
    public var preferStreamsInPreferredAudioLanguage: Bool = true
    /// Whether the order of the addons decides the order of the sources, or the best ones come first whatever addon they are from.
    public var streamOrdering: StreamOrdering = .byAddon
    public var autoSelectStream: Bool = false
    /// With the Automatic engine, Matroska files are converted on the fly for AVPlayer instead of being opened with MPV: AVPlayer can
    /// then float the picture (Picture in Picture) and send it to an AirPlay receiver. The AVPlayer engine always converts them.
    public var convertMatroskaForAVPlayer: Bool = false
    public var controlsAutoHideSeconds: Int = 4
    public var landscapeOnly: Bool = true
    public var gesturesEnabled: Bool = true
    public var watchedThreshold: Double = 0.9
    public var video: VideoOutputSettings = VideoOutputSettings()
    /// Tried when the preferred language is not available ("off" = none).
    public var secondaryAudioLanguage: String = "off"
    public var secondarySubtitleLanguage: String = "off"
    /// Removes hearing-impaired annotations ("[music]", "(sighs)", "♪ …") from subtitles Aether renders itself.
    public var stripHearingImpairedTags: Bool = false
    /// Press and hold on the picture to play at `holdSpeed`, release to go back.
    public var holdToSpeed: Bool = true
    public var holdSpeed: Double = 2
    /// Offers "Salta intro" / "Salta riassunto" on episodes IntroDB knows the timing of. Looking it up sends the show's IMDb
    /// code, the season and the episode to introdb.app (no account, no key).
    public var skipSegmentsEnabled: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case video, secondaryAudioLanguage, secondarySubtitleLanguage, stripHearingImpairedTags, holdToSpeed, holdSpeed
        case engine, autoResume, resumeRewindSeconds, skipBackSeconds, skipForwardSeconds, autoplayNextEpisode
        case nextEpisodeCountdownSeconds, preferredAudioLanguage, preferredSubtitleLanguage, subtitleStyle
        case subtitleDelaySeconds, autoPictureInPicture, allowBackgroundAudio, defaultSleepTimerMinutes, qualityCap
        case preferStreamsInPreferredAudioLanguage, autoSelectStream, controlsAutoHideSeconds, landscapeOnly
        case gesturesEnabled, watchedThreshold, skipSegmentsEnabled, streamOrdering, convertMatroskaForAVPlayer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = c.value(.engine, default: .automatic)
        autoResume = c.value(.autoResume, default: true)
        resumeRewindSeconds = min(30, max(0, c.value(.resumeRewindSeconds, default: 0)))
        skipBackSeconds = min(120, max(5, c.value(.skipBackSeconds, default: 10)))
        skipForwardSeconds = min(120, max(5, c.value(.skipForwardSeconds, default: 10)))
        autoplayNextEpisode = c.value(.autoplayNextEpisode, default: true)
        nextEpisodeCountdownSeconds = min(30, max(0, c.value(.nextEpisodeCountdownSeconds, default: 8)))
        preferredAudioLanguage = c.value(.preferredAudioLanguage, default: "system")
        preferredSubtitleLanguage = c.value(.preferredSubtitleLanguage, default: "off")
        subtitleStyle = c.value(.subtitleStyle, default: SubtitleStyle())
        subtitleDelaySeconds = min(60, max(-60, c.value(.subtitleDelaySeconds, default: 0.0)))
        autoPictureInPicture = c.value(.autoPictureInPicture, default: true)
        allowBackgroundAudio = c.value(.allowBackgroundAudio, default: true)
        defaultSleepTimerMinutes = max(0, c.value(.defaultSleepTimerMinutes, default: 0))
        qualityCap = c.value(.qualityCap, default: .auto)
        preferStreamsInPreferredAudioLanguage = c.value(.preferStreamsInPreferredAudioLanguage, default: true)
        streamOrdering = c.value(.streamOrdering, default: .byAddon)
        autoSelectStream = c.value(.autoSelectStream, default: false)
        convertMatroskaForAVPlayer = c.value(.convertMatroskaForAVPlayer, default: false)
        controlsAutoHideSeconds = min(15, max(2, c.value(.controlsAutoHideSeconds, default: 4)))
        landscapeOnly = c.value(.landscapeOnly, default: true)
        gesturesEnabled = c.value(.gesturesEnabled, default: true)
        watchedThreshold = min(0.99, max(0.5, c.value(.watchedThreshold, default: 0.9)))
        video = c.value(.video, default: VideoOutputSettings())
        secondaryAudioLanguage = c.value(.secondaryAudioLanguage, default: "off")
        secondarySubtitleLanguage = c.value(.secondarySubtitleLanguage, default: "off")
        stripHearingImpairedTags = c.value(.stripHearingImpairedTags, default: false)
        holdToSpeed = c.value(.holdToSpeed, default: true)
        holdSpeed = min(4, max(1.25, c.value(.holdSpeed, default: 2.0)))
        skipSegmentsEnabled = c.value(.skipSegmentsEnabled, default: true)
    }
}

public struct ContentSettings: Codable, Equatable, Sendable {
    /// "system" or a language code; used to rank streams/subtitles and to label UI hints.
    public var preferredLanguage: String = "system"
    /// Minutes a catalog response is considered fresh (overrides the default, never an addon's explicit `cacheMaxAge`).
    public var catalogRefreshMinutes: Int = 10
    public var hideAdultCatalogs: Bool = true
    public var searchRemote: Bool = true
    public var searchLocal: Bool = true
    public var saveSearchHistory: Bool = true
    public var searchSort: SearchSort = .relevance
    /// The user's order and visibility of the content types in Discover (`DiscoverLayout` reconciles it with the types
    /// the installed addons provide). Empty until the user changes something: then every type is shown, in canonical order.
    /// Entries of types nobody provides right now are kept, so reinstalling an addon restores the choice.
    public var discoverTypes: [DiscoverTypeSetting] = []
    // 1.5
    /// The viewer's names and order for the addons' catalogs (Home, Discover, Search).
    public var catalogLayout = CatalogLayoutSettings()
    /// How the sources are written in the picker (logo of the addon, badges, own pattern).
    public var streamDisplay = StreamDisplaySettings()
    /// Which TMDB parts of the title page are shown.
    public var titleModules = TitleModulesSettings()
    /// Ratings from MDBList: on/off and which services.
    public var ratings = RatingsSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case preferredLanguage, catalogRefreshMinutes, hideAdultCatalogs, searchRemote, searchLocal
        case saveSearchHistory, searchSort, discoverTypes
        case catalogLayout, streamDisplay, titleModules, ratings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredLanguage = c.value(.preferredLanguage, default: "system")
        catalogRefreshMinutes = min(1440, max(1, c.value(.catalogRefreshMinutes, default: 10)))
        hideAdultCatalogs = c.value(.hideAdultCatalogs, default: true)
        searchRemote = c.value(.searchRemote, default: true)
        searchLocal = c.value(.searchLocal, default: true)
        saveSearchHistory = c.value(.saveSearchHistory, default: true)
        searchSort = c.value(.searchSort, default: .relevance)
        discoverTypes = c.lossyArray(DiscoverTypeSetting.self, forKey: .discoverTypes)
        catalogLayout = c.value(.catalogLayout, default: CatalogLayoutSettings())
        streamDisplay = c.value(.streamDisplay, default: StreamDisplaySettings())
        titleModules = c.value(.titleModules, default: TitleModulesSettings())
        ratings = c.value(.ratings, default: RatingsSettings())
    }
}

public struct CastingSettings: Codable, Equatable, Sendable {
    public var airPlayEnabled: Bool = true
    public var googleCastEnabled: Bool = true
    public var dlnaEnabled: Bool = true
    /// SSDP multicast discovery needs Apple's multicast entitlement; manual add always works.
    public var ssdpDiscoveryEnabled: Bool = false
    public var resumeLocallyOnDisconnect: Bool = true
    public var manualDLNAHosts: [String] = []
    /// Matroska files sent to Google Cast are converted by the phone into HLS (video and audio copied, not re-encoded), which every
    /// Cast receiver reads; without it the receiver is given the MKV as it is and many refuse it.
    public var convertMatroskaForGoogleCast: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case airPlayEnabled, googleCastEnabled, dlnaEnabled, ssdpDiscoveryEnabled, resumeLocallyOnDisconnect, manualDLNAHosts
        case convertMatroskaForGoogleCast
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        airPlayEnabled = c.value(.airPlayEnabled, default: true)
        googleCastEnabled = c.value(.googleCastEnabled, default: true)
        dlnaEnabled = c.value(.dlnaEnabled, default: true)
        ssdpDiscoveryEnabled = c.value(.ssdpDiscoveryEnabled, default: false)
        resumeLocallyOnDisconnect = c.value(.resumeLocallyOnDisconnect, default: true)
        manualDLNAHosts = c.value(.manualDLNAHosts, default: [])
        convertMatroskaForGoogleCast = c.value(.convertMatroskaForGoogleCast, default: true)
    }
}

public enum SeasonDownloadSizePolicy: String, Codable, CaseIterable, Sendable {
    /// Prefer the lightest file among the best quality available within the selected cap.
    case preferSmaller
    /// Prefer quality; file size is only a tie-breaker.
    case any

    public var title: String {
        switch self {
        case .preferSmaller: return "File più leggeri"
        case .any: return "Qualsiasi peso (qualità prioritaria)"
        }
    }
}

public struct StorageSettings: Codable, Equatable, Sendable {
    public var imageCacheLimitMB: Int = 300
    public var cacheMetadata: Bool = true
    public var downloadOverCellular: Bool = false
    public var maxConcurrentDownloads: Int = 2
    public var deleteDownloadsAfterWatching: Bool = false
    /// Quality cap used by the one-tap season downloader. Auto follows the best matching source.
    public var seasonDownloadQuality: VideoQualityCap = .auto
    /// "preferred" follows playback language, "any" disables language filtering, otherwise an ISO language code.
    public var seasonDownloadLanguage: String = "preferred"
    public var seasonDownloadSizePolicy: SeasonDownloadSizePolicy = .preferSmaller

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case imageCacheLimitMB, cacheMetadata, downloadOverCellular, maxConcurrentDownloads, deleteDownloadsAfterWatching
        case seasonDownloadQuality, seasonDownloadLanguage, seasonDownloadSizePolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageCacheLimitMB = min(4096, max(20, c.value(.imageCacheLimitMB, default: 300)))
        cacheMetadata = c.value(.cacheMetadata, default: true)
        downloadOverCellular = c.value(.downloadOverCellular, default: false)
        maxConcurrentDownloads = min(4, max(1, c.value(.maxConcurrentDownloads, default: 2)))
        deleteDownloadsAfterWatching = c.value(.deleteDownloadsAfterWatching, default: false)
        seasonDownloadQuality = c.value(.seasonDownloadQuality, default: .auto)
        seasonDownloadLanguage = c.value(.seasonDownloadLanguage, default: "preferred")
        seasonDownloadSizePolicy = c.value(.seasonDownloadSizePolicy, default: .preferSmaller)
    }
}

public struct PrivacySettings: Codable, Equatable, Sendable {
    /// Master switch for watch history / resume points / search history. Off = nothing is recorded.
    public var recordHistory: Bool = true
    /// Permit addons, streams and Cast/DLNA devices on private (LAN) addresses.
    public var allowLocalNetwork: Bool = false
    public var keepDiagnosticLog: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case recordHistory, allowLocalNetwork, keepDiagnosticLog }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordHistory = c.value(.recordHistory, default: true)
        allowLocalNetwork = c.value(.allowLocalNetwork, default: false)
        keepDiagnosticLog = c.value(.keepDiagnosticLog, default: true)
    }
}

public struct AdvancedSettings: Codable, Equatable, Sendable {
    /// Experimental: map torrent streams to a user-run Stremio streaming server. Off by default; unverified.
    public var useExternalStreamingServer: Bool = false
    public var streamingServerURL: String = ""
    public var verboseLogging: Bool = false
    /// Hand the television the original link of a source that carries the user's account key, instead of letting the phone relay the
    /// video. Off by default: with it on, whoever controls the television (or listens on the Wi-Fi) can read the key.
    public var sendDirectLinkToTV: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case useExternalStreamingServer, streamingServerURL, verboseLogging, sendDirectLinkToTV }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useExternalStreamingServer = c.value(.useExternalStreamingServer, default: false)
        streamingServerURL = c.value(.streamingServerURL, default: "")
        verboseLogging = c.value(.verboseLogging, default: false)
        sendDirectLinkToTV = c.value(.sendDirectLinkToTV, default: false)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = AppSettings.currentVersion
    public var appearance = AppearanceSettings()
    public var playback = PlaybackSettings()
    public var content = ContentSettings()
    public var casting = CastingSettings()
    public var storage = StorageSettings()
    public var privacy = PrivacySettings()
    public var advanced = AdvancedSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, appearance, playback, content, casting, storage, privacy, advanced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = AppSettings.currentVersion
        appearance = c.value(.appearance, default: AppearanceSettings())
        playback = c.value(.playback, default: PlaybackSettings())
        content = c.value(.content, default: ContentSettings())
        casting = c.value(.casting, default: CastingSettings())
        storage = c.value(.storage, default: StorageSettings())
        privacy = c.value(.privacy, default: PrivacySettings())
        advanced = c.value(.advanced, default: AdvancedSettings())
    }

    /// The library policy derived from the user's settings.
    public var libraryPolicy: LibraryPolicy {
        return LibraryPolicy(watchedThreshold: playback.watchedThreshold,
                             minimumRecordedSeconds: 10,
                             recordHistory: privacy.recordHistory)
    }

    /// The network policy derived from the user's settings. `allowLoopback` is only for tests / dev builds.
    public func networkPolicy(allowLoopback: Bool = false, resolver: HostResolving = SystemHostResolver()) -> NetworkPolicy {
        return NetworkPolicy(allowLocalNetwork: privacy.allowLocalNetwork, allowLoopback: allowLoopback,
                             requireHTTPSForPublicHosts: true, checkDNS: true, resolver: resolver)
    }
}
