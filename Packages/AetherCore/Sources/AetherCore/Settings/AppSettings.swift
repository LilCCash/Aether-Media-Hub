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

    public init(id: String, isVisible: Bool = true) {
        self.id = id
        self.isVisible = isVisible
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
    public var posterSize: PosterSize = .medium
    public var density: CatalogDensity = .comfortable
    public var animationsEnabled: Bool = true
    public var reduceVisualEffects: Bool = false
    public var homeSections: [HomeSectionConfig] = HomeSectionConfig.defaultOrder

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case theme, accent, posterSize, density, animationsEnabled, reduceVisualEffects, homeSections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = c.value(.theme, default: .system)
        accent = c.value(.accent, default: .aurora)
        posterSize = c.value(.posterSize, default: .medium)
        density = c.value(.density, default: .comfortable)
        animationsEnabled = c.value(.animationsEnabled, default: true)
        reduceVisualEffects = c.value(.reduceVisualEffects, default: false)
        let stored = c.lossyArray(HomeSectionConfig.self, forKey: .homeSections)
        homeSections = AppearanceSettings.normalise(sections: stored)
    }

    /// Keeps known sections, preserves stored order/visibility, appends any new section at the end.
    public static func normalise(sections stored: [HomeSectionConfig]) -> [HomeSectionConfig] {
        let known = Set(HomeSectionConfig.defaultOrder.map { $0.id })
        var result: [HomeSectionConfig] = []
        var seen = Set<String>()
        for section in stored where known.contains(section.id) && seen.insert(section.id).inserted {
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
    public var autoSelectStream: Bool = false
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

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case video, secondaryAudioLanguage, secondarySubtitleLanguage, stripHearingImpairedTags, holdToSpeed, holdSpeed
        case engine, autoResume, resumeRewindSeconds, skipBackSeconds, skipForwardSeconds, autoplayNextEpisode
        case nextEpisodeCountdownSeconds, preferredAudioLanguage, preferredSubtitleLanguage, subtitleStyle
        case subtitleDelaySeconds, autoPictureInPicture, allowBackgroundAudio, defaultSleepTimerMinutes, qualityCap
        case preferStreamsInPreferredAudioLanguage, autoSelectStream, controlsAutoHideSeconds, landscapeOnly
        case gesturesEnabled, watchedThreshold
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
        autoSelectStream = c.value(.autoSelectStream, default: false)
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

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case preferredLanguage, catalogRefreshMinutes, hideAdultCatalogs, searchRemote, searchLocal
        case saveSearchHistory, searchSort
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

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case airPlayEnabled, googleCastEnabled, dlnaEnabled, ssdpDiscoveryEnabled, resumeLocallyOnDisconnect, manualDLNAHosts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        airPlayEnabled = c.value(.airPlayEnabled, default: true)
        googleCastEnabled = c.value(.googleCastEnabled, default: true)
        dlnaEnabled = c.value(.dlnaEnabled, default: true)
        ssdpDiscoveryEnabled = c.value(.ssdpDiscoveryEnabled, default: false)
        resumeLocallyOnDisconnect = c.value(.resumeLocallyOnDisconnect, default: true)
        manualDLNAHosts = c.value(.manualDLNAHosts, default: [])
    }
}

public struct StorageSettings: Codable, Equatable, Sendable {
    public var imageCacheLimitMB: Int = 300
    public var cacheMetadata: Bool = true
    public var downloadOverCellular: Bool = false
    public var maxConcurrentDownloads: Int = 2
    public var deleteDownloadsAfterWatching: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case imageCacheLimitMB, cacheMetadata, downloadOverCellular, maxConcurrentDownloads, deleteDownloadsAfterWatching
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageCacheLimitMB = min(4096, max(20, c.value(.imageCacheLimitMB, default: 300)))
        cacheMetadata = c.value(.cacheMetadata, default: true)
        downloadOverCellular = c.value(.downloadOverCellular, default: false)
        maxConcurrentDownloads = min(4, max(1, c.value(.maxConcurrentDownloads, default: 2)))
        deleteDownloadsAfterWatching = c.value(.deleteDownloadsAfterWatching, default: false)
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

    public init() {}

    private enum CodingKeys: String, CodingKey { case useExternalStreamingServer, streamingServerURL, verboseLogging }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useExternalStreamingServer = c.value(.useExternalStreamingServer, default: false)
        streamingServerURL = c.value(.streamingServerURL, default: "")
        verboseLogging = c.value(.verboseLogging, default: false)
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
