package app.aether.core.playback

import app.aether.core.model.AddonStream
import app.aether.core.model.StreamSource

enum class StreamQuality(val label: String, val height: Int) {
    UNKNOWN("—", 0), SD("SD", 480), HD720("720p", 720), FULL_HD("1080p", 1080), UHD("4K", 2160)
}

enum class VideoCodec(val label: String) { H264("H.264"), HEVC("HEVC"), AV1("AV1"), VP9("VP9"), MPEG2("MPEG-2"), XVID("Xvid") }

enum class HdrFormat(val label: String) { HDR10("HDR10"), HDR10_PLUS("HDR10+"), DOLBY_VISION("Dolby Vision"), HLG("HLG") }

enum class AudioCodec(val label: String) {
    AAC("AAC"), AC3("Dolby Digital"), EAC3("Dolby Digital+"), DTS("DTS"), TRUEHD("TrueHD"), ATMOS("Atmos"), FLAC("FLAC"), OPUS("Opus"), MP3("MP3")
}

enum class StreamKind { FILE, HLS, DASH, TORRENT, YOUTUBE, EXTERNAL_PAGE, PLAYER_FRAME, ARCHIVE, OTHER }

/** What this build can use to turn a source into something playable. */
data class PlaybackCapabilities(
    /** A TorBox key is saved, so a torrent can be turned into a direct link before playback (nothing says the key is valid). */
    val debridAvailable: Boolean = false,
    /** A Stremio-compatible streaming server the user configured for torrents. */
    val streamingServer: String? = null,
)

sealed class UnsupportedReason(val message: String) {
    class Container(ext: String) : UnsupportedReason("Il contenitore .$ext non è riproducibile dal player di Android TV.")
    object Torrent : UnsupportedReason("Questo è un torrent: serve una chiave TorBox (Impostazioni ▸ Servizi) o un server di streaming.")
    object YouTube : UnsupportedReason("Video YouTube: non c'è un player YouTube integrato.")
    object ExternalPage : UnsupportedReason("Questa sorgente è una pagina web esterna, non un flusso video.")
    object PlayerFrame : UnsupportedReason("Sorgente basata su un player incorporato (iframe), non supportata.")
    class Archive(kind: String) : UnsupportedReason("Sorgente $kind (archivio/usenet): richiede il server di streaming Stremio.")
    class Transport(scheme: String) : UnsupportedReason("Protocollo «$scheme» non supportato.")
    object LocalStreamingServer : UnsupportedReason("La sorgente punta al server Stremio locale (127.0.0.1:11470), che non esiste su questo dispositivo.")
    object InvalidUrl : UnsupportedReason("URL della sorgente non valido.")
}

sealed class PlaybackSupport {
    object Supported : PlaybackSupport()
    /** Cannot tell without trying (no recognisable extension). */
    object Unknown : PlaybackSupport()
    class Unsupported(val reason: UnsupportedReason) : PlaybackSupport()

    val isPlayable: Boolean get() = this !is Unsupported
}

data class StreamInfo(
    val quality: StreamQuality,
    val codec: VideoCodec?,
    /** Formats the *release name* claims: text found in a title, not a measurement of the file or of what the TV shows. */
    val hdr: List<HdrFormat>,
    val audio: List<AudioCodec>,
    val languages: List<String>,
    val sizeBytes: Long?,
    val kind: StreamKind,
    val container: String?,
    val support: PlaybackSupport,
    val warnings: List<String>,
    val needsHeaders: Boolean,
    /** "MKV", "MP4", "HLS"… from the link or the declared file name, never guessed. */
    val formatLabel: String?,
) {
    /** One-line badges, e.g. "1080p · HEVC · HDR10 (nel nome) · Dolby Digital+". */
    val badges: List<String>
        get() = buildList {
            if (quality != StreamQuality.UNKNOWN) add(quality.label)
            codec?.let { add(it.label) }
            hdr.forEach { add("${it.label} (nel nome)") }
            audio.firstOrNull()?.let { add(it.label) }
        }

    val sizeLabel: String?
        get() {
            val size = sizeBytes?.takeIf { it > 0 } ?: return null
            val gb = size / 1_073_741_824.0
            return if (gb >= 1) "%.1f GB".format(gb) else "%.0f MB".format(size / 1_048_576.0)
        }
}

/** Derives playable-ness and presentation info from an addon stream. Pure and deterministic. */
object StreamAnalyzer {
    /** Containers ExoPlayer (Media3) opens natively. */
    val supportedContainers = setOf(
        "mp4", "m4v", "mov", "mkv", "mka", "webm", "ts", "m2ts", "mts", "m3u8", "mpd", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
        "ac3", "ec3", "3gp", "flv", "mpg", "mpeg", "ps", "vob",
    )
    /** Containers it does not. */
    val unsupportedContainers = setOf("avi", "wmv", "divx", "asf", "rmvb", "ogm", "ogv")

    private val formatNames = mapOf(
        "mkv" to "MKV", "avi" to "AVI", "mp4" to "MP4", "mov" to "MOV", "m4v" to "M4V", "ts" to "TS", "m2ts" to "M2TS", "webm" to "WEBM",
        "wmv" to "WMV", "flv" to "FLV", "mpg" to "MPEG", "mpeg" to "MPEG", "ogv" to "OGV", "ogm" to "OGM", "vob" to "VOB", "divx" to "DIVX",
        "rmvb" to "RMVB", "3gp" to "3GP", "asf" to "ASF", "m3u8" to "HLS", "mpd" to "DASH",
    )

    fun analyze(stream: AddonStream, capabilities: PlaybackCapabilities = PlaybackCapabilities()): StreamInfo {
        val text = stream.searchableText
        val lower = text.lowercase()
        val tokens = tokenize(text)
        val warnings = ArrayList<String>()
        val quality = detectQuality(lower, tokens)
        val codec = detectCodec(tokens, lower)
        val hdr = detectHdr(tokens, lower)
        val audio = detectAudio(tokens, lower)
        val languages = detectLanguages(text, tokens)
        val size = stream.behaviorHints.videoSize ?: detectSize(text)

        if (audio.any { it == AudioCodec.DTS || it == AudioCodec.TRUEHD } &&
            audio.none { it == AudioCodec.AAC || it == AudioCodec.AC3 || it == AudioCodec.EAC3 || it == AudioCodec.ATMOS }
        ) warnings.add("Audio DTS/TrueHD: dipende dalla TV; se manca l'audio scegli un'altra sorgente.")
        if (codec == VideoCodec.AV1) warnings.add("AV1 richiede un decoder hardware: non tutte le TV lo hanno.")
        val needsHeaders = stream.behaviorHints.proxyRequestHeaders.isNotEmpty()

        var kind = StreamKind.OTHER
        var container: String? = null
        var support: PlaybackSupport = PlaybackSupport.Unknown

        when (val source = stream.source) {
            is StreamSource.Url -> {
                val url = source.url.trim()
                val scheme = url.substringBefore("://", "").lowercase()
                val host = url.substringAfter("://", "").substringBefore('/').substringBefore('?').lowercase()
                val path = url.substringAfter("://", url).substringAfter('/', "").substringBefore('?').substringBefore('#')
                val extension = path.substringAfterLast('/', path).substringAfterLast('.', "").lowercase()
                val hintExtension = filenameExtension(stream.behaviorHints.filename)
                when {
                    scheme.isEmpty() || !url.contains("://") -> { support = PlaybackSupport.Unsupported(UnsupportedReason.InvalidUrl) }
                    scheme != "http" && scheme != "https" -> { support = PlaybackSupport.Unsupported(UnsupportedReason.Transport(scheme)) }
                    isLocalStreamingServer(host) -> { support = PlaybackSupport.Unsupported(UnsupportedReason.LocalStreamingServer) }
                    extension == "m3u8" || (extension.isEmpty() && url.lowercase().contains(".m3u8")) -> {
                        kind = StreamKind.HLS; container = "m3u8"; support = PlaybackSupport.Supported
                    }
                    extension == "mpd" -> { kind = StreamKind.DASH; container = "mpd"; support = PlaybackSupport.Supported }
                    else -> {
                        kind = StreamKind.FILE
                        val chosen = if (extension.isNotEmpty() && (extension in supportedContainers || extension in unsupportedContainers)) extension else hintExtension
                        container = chosen.ifEmpty { null }
                        support = when {
                            container == null -> PlaybackSupport.Unknown
                            container in supportedContainers -> PlaybackSupport.Supported
                            container in unsupportedContainers -> PlaybackSupport.Unsupported(UnsupportedReason.Container(container!!))
                            else -> PlaybackSupport.Unknown
                        }
                    }
                }
            }
            is StreamSource.YouTube -> { kind = StreamKind.YOUTUBE; support = PlaybackSupport.Unsupported(UnsupportedReason.YouTube) }
            is StreamSource.Torrent -> {
                kind = StreamKind.TORRENT
                support = when {
                    capabilities.debridAvailable -> PlaybackSupport.Unknown
                    capabilities.streamingServer != null -> { warnings.add("Torrent tramite server esterno (sperimentale)."); PlaybackSupport.Unknown }
                    else -> PlaybackSupport.Unsupported(UnsupportedReason.Torrent)
                }
            }
            is StreamSource.External -> { kind = StreamKind.EXTERNAL_PAGE; support = PlaybackSupport.Unsupported(UnsupportedReason.ExternalPage) }
            is StreamSource.PlayerFrame -> { kind = StreamKind.PLAYER_FRAME; support = PlaybackSupport.Unsupported(UnsupportedReason.PlayerFrame) }
            is StreamSource.Archive -> { kind = StreamKind.ARCHIVE; support = PlaybackSupport.Unsupported(UnsupportedReason.Archive(source.kind)) }
            StreamSource.Unknown -> { support = PlaybackSupport.Unsupported(UnsupportedReason.InvalidUrl) }
        }

        val format = when (kind) {
            StreamKind.HLS -> "HLS"
            StreamKind.DASH -> "DASH"
            StreamKind.FILE -> container?.let { formatNames[it.lowercase()] }
            StreamKind.TORRENT -> formatNames[filenameExtension(stream.behaviorHints.filename)]
            else -> null
        }
        return StreamInfo(quality, codec, hdr, audio, languages, size, kind, container, support, warnings, needsHeaders, format)
    }

    // MARK: Detection

    fun tokenize(text: String): Set<String> {
        val tokens = HashSet<String>()
        val current = StringBuilder()
        for (c in text.lowercase()) {
            if (c.isLetterOrDigit() || c == '+') current.append(c) else if (current.isNotEmpty()) { tokens.add(current.toString()); current.clear() }
        }
        if (current.isNotEmpty()) tokens.add(current.toString())
        return tokens
    }

    fun detectQuality(text: String, tokens: Set<String>): StreamQuality = when {
        tokens.any { it == "2160p" || it == "4k" || it == "uhd" || it == "2160" } -> StreamQuality.UHD
        tokens.any { it == "1080p" || it == "1080i" || it == "fhd" || it == "1080" } -> StreamQuality.FULL_HD
        tokens.any { it == "720p" || it == "720" } -> StreamQuality.HD720
        tokens.any { it == "480p" || it == "576p" || it == "sd" || it == "dvdrip" } -> StreamQuality.SD
        text.contains("x1080") -> StreamQuality.FULL_HD
        text.contains("x2160") -> StreamQuality.UHD
        text.contains("x720") -> StreamQuality.HD720
        else -> StreamQuality.UNKNOWN
    }

    fun detectCodec(tokens: Set<String>, text: String): VideoCodec? = when {
        tokens.any { it == "hevc" || it == "x265" || it == "h265" } || text.contains("h.265") -> VideoCodec.HEVC
        "av1" in tokens -> VideoCodec.AV1
        tokens.any { it == "x264" || it == "h264" || it == "avc" } || text.contains("h.264") -> VideoCodec.H264
        "vp9" in tokens -> VideoCodec.VP9
        "xvid" in tokens || "divx" in tokens -> VideoCodec.XVID
        "mpeg2" in tokens -> VideoCodec.MPEG2
        else -> null
    }

    fun detectHdr(tokens: Set<String>, text: String): List<HdrFormat> = buildList {
        if ("dv" in tokens || "dovi" in tokens || text.contains("dolby vision") || text.contains("dolbyvision")) add(HdrFormat.DOLBY_VISION)
        if ("hdr10+" in tokens || "hdr10plus" in tokens) add(HdrFormat.HDR10_PLUS) else if ("hdr10" in tokens || "hdr" in tokens) add(HdrFormat.HDR10)
        if ("hlg" in tokens) add(HdrFormat.HLG)
    }

    fun detectAudio(tokens: Set<String>, text: String): List<AudioCodec> {
        val result = ArrayList<AudioCodec>()
        fun add(codec: AudioCodec) { if (codec !in result) result.add(codec) }
        if ("atmos" in tokens) add(AudioCodec.ATMOS)
        if ("truehd" in tokens) add(AudioCodec.TRUEHD)
        if (tokens.any { it == "eac3" || it == "ddp" || it == "dd+" } || text.contains("dd+") || text.contains("e-ac-3")) add(AudioCodec.EAC3)
        if (tokens.any { it == "ac3" || it == "dd5" } || text.contains("dolby digital")) add(AudioCodec.AC3)
        if (tokens.any { it == "dts" || it == "dtshd" } || text.contains("dts-hd")) add(AudioCodec.DTS)
        if ("aac" in tokens) add(AudioCodec.AAC)
        if ("flac" in tokens) add(AudioCodec.FLAC)
        if ("opus" in tokens) add(AudioCodec.OPUS)
        if ("mp3" in tokens) add(AudioCodec.MP3)
        return result
    }

    private val languageTokens = mapOf(
        "ita" to "it", "italian" to "it", "italiano" to "it", "eng" to "en", "english" to "en",
        "fra" to "fr", "fre" to "fr", "french" to "fr", "vff" to "fr", "spa" to "es", "spanish" to "es", "esp" to "es", "latino" to "es",
        "ger" to "de", "deu" to "de", "german" to "de", "por" to "pt", "portuguese" to "pt", "rus" to "ru", "russian" to "ru",
        "jpn" to "ja", "jap" to "ja", "japanese" to "ja", "kor" to "ko", "korean" to "ko", "hin" to "hi", "hindi" to "hi",
        "chi" to "zh", "chinese" to "zh", "multi" to "multi", "dual" to "multi",
    )

    private val flagLanguages = mapOf(
        "IT" to "it", "GB" to "en", "US" to "en", "FR" to "fr", "ES" to "es", "DE" to "de", "PT" to "pt", "BR" to "pt",
        "RU" to "ru", "JP" to "ja", "KR" to "ko", "IN" to "hi", "CN" to "zh",
    )

    fun detectLanguages(text: String, tokens: Set<String>): List<String> {
        val result = ArrayList<String>()
        for ((token, code) in languageTokens) if (token in tokens && code !in result) result.add(code)
        // A flag emoji is two regional-indicator code points.
        val points = text.codePoints().toArray()
        var index = 0
        while (index + 1 < points.size) {
            val a = points[index]
            val b = points[index + 1]
            if (a in 0x1F1E6..0x1F1FF && b in 0x1F1E6..0x1F1FF) {
                val code = "" + (a - 0x1F1E6 + 65).toChar() + (b - 0x1F1E6 + 65).toChar()
                flagLanguages[code]?.let { if (it !in result) result.add(it) }
                index += 2
            } else {
                index++
            }
        }
        return result.sorted()
    }

    private val sizeRegex = Regex("(\\d+(?:[.,]\\d+)?)\\s?(gb|gib|mb|mib)\\b", RegexOption.IGNORE_CASE)

    fun detectSize(text: String): Long? {
        val match = sizeRegex.find(text) ?: return null
        val number = match.groupValues[1].replace(',', '.').toDoubleOrNull() ?: return null
        val multiplier = if (match.groupValues[2].lowercase().startsWith("g")) 1_073_741_824.0 else 1_048_576.0
        val bytes = number * multiplier
        return if (bytes > 0 && bytes < 1e13) bytes.toLong() else null
    }

    fun filenameExtension(filename: String?): String {
        val name = filename ?: return ""
        val dot = name.lastIndexOf('.')
        if (dot < 0) return ""
        val ext = name.substring(dot + 1).lowercase()
        return if (ext.length <= 5) ext else ""
    }

    private fun isLocalStreamingServer(host: String): Boolean =
        (host.startsWith("127.0.0.1") || host.startsWith("localhost") || host.startsWith("[::1]")) && host.endsWith(":11470")
}

/** Maps a stream to the URL actually handed to a player. */
object StreamResolver {
    /** The direct http(s) URL for the stream, or a streaming-server URL for a torrent when the user configured a server. */
    fun playbackUrl(stream: AddonStream, streamingServer: String?): String? = when (val source = stream.source) {
        is StreamSource.Url -> source.url.trim().takeIf { it.startsWith("http://", true) || it.startsWith("https://", true) }
        is StreamSource.Torrent -> {
            if (streamingServer == null || !isValidInfoHash(source.infoHash)) null
            else {
                val base = streamingServer.trimEnd('/')
                val trackers = source.trackers.joinToString("&") { "tr=" + app.aether.core.addons.ResourceUrlBuilder.encode(it) }
                "$base/${source.infoHash.lowercase()}/${source.fileIndex ?: -1}" + if (trackers.isEmpty()) "" else "?$trackers"
            }
        }
        else -> null
    }

    fun isValidInfoHash(hash: String): Boolean = hash.length == 40 && hash.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
