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
data class AppearanceSettings(
    val accent: AccentChoice = AccentChoice.AURORA,
    val posterSize: PosterSize = PosterSize.MEDIUM,
    val animationsEnabled: Boolean = true,
    val heroAutoScroll: Boolean = true,
    val showContinueWatching: Boolean = true,
    val showNextUp: Boolean = true,
    /** Ids of Home sections the viewer hid ("continue", "nextup", or a catalog reference id). */
    val hiddenHomeSections: List<String> = emptyList(),
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
)

@Serializable
data class ContentSettings(
    /** "system" or a language code (metadata language). */
    val preferredLanguage: String = "system",
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
    /** The viewer's choice about the Cinemeta recommendation shown in the empty state; never installed silently. */
    val cinemetaOffered: Boolean = false,
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
