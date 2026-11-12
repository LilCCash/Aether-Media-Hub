package app.aether.core.settings

import app.aether.core.playback.StreamOrdering
import app.aether.core.playback.VideoQualityCap
import app.aether.core.search.SearchSort
import app.aether.core.util.JsonFileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable
enum class AccentChoice(val title: String, val argb: Long) {
    AURORA("Aurora", 0xFF8B7CFF), AMBER("Ambra", 0xFFFFB347), CORAL("Corallo", 0xFFFF6B6B), EMERALD("Smeraldo", 0xFF3DDC97),
    SKY("Cielo", 0xFF4FB3FF), ROSE("Rosa", 0xFFFF7EB6),
}

@Serializable
enum class PosterSize(val title: String, val scale: Float) { SMALL("Piccole", 0.85f), MEDIUM("Medie", 1f), LARGE("Grandi", 1.2f) }

@Serializable
enum class BackgroundStyle(val title: String) { NIGHT("Notte"), AURORA("Aurora (si muove piano)"), CINEMA("Cinema"), OCEAN("Oceano"), EMBER("Braci") }

@Serializable
enum class CornerStyle(val title: String, val dp: Int) { SHARP("Squadrati", 4), SOFT("Morbidi", 12), ROUND("Molto tondi", 22) }

/** How much the interface draws: «Automatica» picks by the TV's memory and processor. */
@Serializable
enum class GraphicsQuality(val title: String, val detail: String) {
    AUTO("Automatica", "Scelta in base alla potenza della TV"),
    FULL("Completa", "Sfocature, ombre, immagini di sfondo e animazioni"),
    BALANCED("Bilanciata", "Ombre e animazioni brevi, senza sfocature"),
    LIGHT("Leggera", "Niente effetti né animazioni: per le TV più lente"),
}

/** The single effects; null means «as the chosen level says». */
@Serializable
data class GraphicsOverrides(
    val blur: Boolean? = null,
    val shadows: Boolean? = null,
    val backdropArt: Boolean? = null,
    val imageFades: Boolean? = null,
)

@Serializable
data class AppearanceSettings(
    val accent: AccentChoice = AccentChoice.AURORA,
    val posterSize: PosterSize = PosterSize.MEDIUM,
    val animationsEnabled: Boolean = true,
    val background: BackgroundStyle = BackgroundStyle.NIGHT,
    val corners: CornerStyle = CornerStyle.SOFT,
    val heroAutoScroll: Boolean = true,
    val showContinueWatching: Boolean = true,
    val showNextUp: Boolean = true,
    /** Ids of Home sections the viewer hid ("continue", "nextup", or a catalog reference id). */
    val hiddenHomeSections: List<String> = emptyList(),
    /** The order of the Home sections chosen by the viewer (same ids); sections not listed keep their natural place after these. */
    val homeSectionOrder: List<String> = emptyList(),
    /** The order of the sections of a title page (ids of [DetailSections]); empty = the standard order. */
    val detailSectionOrder: List<String> = emptyList(),
    val hiddenDetailSections: List<String> = emptyList(),
    /** The big featured titles at the top of the Home. */
    val showHero: Boolean = true,
    /** «Ciao, Nome!» at the top of the Home. */
    val showGreeting: Boolean = false,
    val greetingName: String = "",
    val graphics: GraphicsQuality = GraphicsQuality.AUTO,
    /** Extra margin around the picture, in percent of the screen, for TVs that crop the edges (0–6). */
    val overscanPercent: Int = 0,
    val graphicsOverrides: GraphicsOverrides = GraphicsOverrides(),
)

@Serializable
data class SubtitleStyle(
    val sizePercent: Int = 100,
    val textColor: Long = 0xFFFFFFFF,
    val bold: Boolean = false,
    val outline: Boolean = true,
    val backgroundOpacityPercent: Int = 0,
    val bottomOffsetPercent: Int = 8,
)

@Serializable
data class PlaybackSettings(
    val autoResume: Boolean = true,
    val resumeRewindSeconds: Int = 0,
    val skipBackSeconds: Int = 10,
    val skipForwardSeconds: Int = 10,
    val autoplayNextEpisode: Boolean = true,
    val nextEpisodeCountdownSeconds: Int = 8,
    /** "system", "off" or a language code. */
    val preferredAudioLanguage: String = "system",
    /** LoudnessEnhancer target gain in dB; applied above the TV volume where the device supports it. */
    val audioGainDb: Int = 0,
    val preferredSubtitleLanguage: String = "off",
    val subtitleStyle: SubtitleStyle = SubtitleStyle(),
    val subtitleDelayMillis: Long = 0,
    val qualityCap: VideoQualityCap = VideoQualityCap.AUTO,
    val preferStreamsInPreferredLanguage: Boolean = true,
    val streamOrdering: StreamOrdering = StreamOrdering.BY_ADDON,
    val autoSelectStream: Boolean = false,
    val controlsAutoHideSeconds: Int = 4,
    val watchedThreshold: Double = 0.9,
    val skipSegmentsEnabled: Boolean = true,
    val stripHearingImpairedTags: Boolean = false,
    /** Minutes after which every video pauses by itself; 0 = off. */
    val defaultSleepTimerMinutes: Int = 0,
    /** The film's logo (from fanart.tv) shown while the source is being prepared. */
    val showTitleLogos: Boolean = true,
    /** Pressing Home during a video keeps it in a small window (Picture-in-Picture), where the TV allows it. */
    val pictureInPicture: Boolean = true,
    /** The full OpenSubtitles.org catalogue is asked too (in the viewer's languages), next to the subtitles of the addons. */
    val openSubtitlesCatalog: Boolean = true,
    /** A second language asked of the catalogue besides the preferred one ("off" = none). */
    val secondarySubtitleLanguage: String = "en",
    /** The start screen before a film (logo, then «Guarda» when the source is ready), as on the iPhone. */
    val introMovies: Boolean = true,
    val introSeries: Boolean = false,
    /** The start screen as a scene: the film's backdrop, year, length, genres and plot around the logo. */
    val cinematicOpening: Boolean = true,
    /** After some seconds of pause: the logo, the plot and the cast over the picture. */
    val pauseScreen: Boolean = true,
    /** At the end of a film, a «Titoli di coda» page with cast and crew. */
    val creditsExperience: Boolean = true,
)

/** The sections of a title page, in the standard order. */
object DetailSections {
    val all: List<Pair<String, String>> = listOf(
        "episodes" to "Episodi", "cast" to "Cast", "collection" to "La saga", "ratings" to "Voti", "info" to "Dettagli",
        "crew" to "Dietro la macchina da presa", "trailers" to "Trailer", "similar" to "Titoli simili",
    )

    fun ordered(order: List<String>, hidden: List<String>): List<String> =
        all.map { it.first }.sortedBy { id -> order.indexOf(id).let { if (it < 0) 1000 + all.indexOfFirst { a -> a.first == id } else it } }.filter { it !in hidden }
}

@Serializable
data class ContentSettings(
    /** "system" or a language code (metadata language). */
    val preferredLanguage: String = "system",
    /** Language of plot, genres and details when TMDB is configured (e.g. "it-IT"). */
    val metadataLanguage: String = "it-IT",
    val catalogRefreshMinutes: Int = 10,
    val hideAdultCatalogs: Boolean = true,
    val searchLocal: Boolean = true,
    val saveSearchHistory: Boolean = true,
    val searchSort: SearchSort = SearchSort.RELEVANCE,
    /** The type shown first in the Scopri screen; empty means all. */
    val discoverTypes: List<String> = emptyList(),
)

@Serializable
data class NetworkSettings(
    val allowLocalNetwork: Boolean = false,
    val cacheResponses: Boolean = true,
    /** A Stremio-compatible streaming server for torrents the user runs himself (optional). */
    val streamingServerUrl: String = "",
    /** The debrid service torrents are played through (Impostazioni ▸ Servizi). */
    val debridService: app.aether.core.debrid.DebridService = app.aether.core.debrid.DebridService.TORBOX,
    /** Look for a newer version of the app at start-up. */
    val checkUpdatesAtStart: Boolean = true,
    /** The build the viewer said «Più tardi» to (not proposed again at start-up). */
    val skippedUpdate: Int = 0,
)

@Serializable
data class PrivacySettings(val recordHistory: Boolean = true)

@Serializable
data class AppSettings(
    val schemaVersion: Int = 1,
    val appearance: AppearanceSettings = AppearanceSettings(),
    val playback: PlaybackSettings = PlaybackSettings(),
    val content: ContentSettings = ContentSettings(),
    val network: NetworkSettings = NetworkSettings(),
    val privacy: PrivacySettings = PrivacySettings(),
    val liveTv: app.aether.core.livetv.LiveTvSettings = app.aether.core.livetv.LiveTvSettings(),
    val trakt: app.aether.core.trakt.TraktSettings = app.aether.core.trakt.TraktSettings(),
    /** The viewer's choice about the Cinemeta recommendation shown in the empty state; never installed silently. */
    val cinemetaOffered: Boolean = false,
    /** Universes the viewer follows (shown on the Home) and the order chosen for each. */
    val followedUniverses: List<String> = emptyList(),
    val universeOrders: Map<String, String> = emptyMap(),
    val profile: app.aether.core.profile.ProfileSettings = app.aether.core.profile.ProfileSettings(),
)

/** The settings, persisted on every change, observable as a [StateFlow]. */
class SettingsStore(private val file: JsonFileStore<AppSettings>) {
    private val state = MutableStateFlow(file.load() ?: AppSettings())
    val value: StateFlow<AppSettings> get() = state

    @Synchronized
    fun update(change: (AppSettings) -> AppSettings) {
        val next = change(state.value)
        if (next == state.value) return
        state.value = next
        file.save(next)
    }

    fun reset() = update { AppSettings() }
}
