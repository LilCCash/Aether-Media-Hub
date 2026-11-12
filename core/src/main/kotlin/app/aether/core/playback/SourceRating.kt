package app.aether.core.playback

/**
 * A mark from 0 to 100 for a source, with the reasons, for the list of sources. It reads only what is known before playing (the
 * addon's announcement and the file name, see [StreamInfo]): it says how good the source promises to be, not a measurement. The
 * order of the list stays [StreamSelector]'s; the mark explains it. Same scale and wording as the iOS app.
 */
data class SourceRating(val score: Int, val reasons: List<Reason>) {
    data class Reason(val text: String, val isPositive: Boolean)

    val verdict: String
        get() = when {
            score >= 90 -> "Eccellente"
            score >= 75 -> "Ottima"
            score >= 60 -> "Buona"
            score >= 40 -> "Discreta"
            else -> "Scarsa"
        }

    companion object {
        fun rate(info: StreamInfo, preferences: StreamPreferences): SourceRating {
            val reasons = ArrayList<Reason>()
            fun good(text: String) = reasons.add(Reason(text, true))
            fun bad(text: String) = reasons.add(Reason(text, false))

            if (info.support is PlaybackSupport.Unsupported) return SourceRating(0, listOf(Reason("Non riproducibile su questa TV", false)))

            var quality = when (info.quality) {
                StreamQuality.UHD -> 40
                StreamQuality.FULL_HD -> 32
                StreamQuality.HD720 -> 22
                StreamQuality.SD -> 10
                StreamQuality.UNKNOWN -> 16
            }
            val height = info.quality.height
            when {
                height > 0 && height > preferences.qualityCap.maxHeight -> {
                    quality = maxOf(10, quality - 14); bad("${info.quality.label}: oltre la qualità massima scelta")
                }
                info.quality == StreamQuality.UNKNOWN -> bad("Qualità non indicata")
                info.quality == StreamQuality.UHD || info.quality == StreamQuality.FULL_HD -> good("Risoluzione ${info.quality.label}")
                else -> bad("Risoluzione ${info.quality.label}")
            }

            var language = 15
            val wanted = preferences.preferredLanguage
            if (wanted != null && preferences.preferLanguage) {
                val name = Languages.displayName(wanted).lowercase()
                when {
                    wanted in info.languages -> { language = 25; good("Audio in $name") }
                    "multi" in info.languages -> { language = 18; good("Più lingue audio (probabilmente anche $name)") }
                    info.languages.isEmpty() -> { language = 8; bad("Lingua dell'audio non indicata") }
                    else -> { language = 0; bad("Audio non in $name") }
                }
            }

            var codec = when (info.codec) {
                VideoCodec.H264 -> { good("Video H.264, compatibile ovunque"); 15 }
                VideoCodec.HEVC -> { good("Video HEVC, efficiente"); 13 }
                VideoCodec.AV1 -> { bad("Video AV1: pesante da decodificare"); 8 }
                VideoCodec.VP9 -> 9
                VideoCodec.XVID, VideoCodec.MPEG2 -> { bad("Codec video vecchio"); 4 }
                null -> 10
            }
            if (info.support is PlaybackSupport.Unknown) {
                codec = minOf(codec, 6); bad("Formato da verificare all'apertura")
            }

            val decoders = preferences.capabilities.decoders
            if (decoders != null && info.codec != null && info.codec != VideoCodec.H264 && info.codec !in decoders) {
                codec = 0; bad("Questa TV non ha il decoder ${info.codec.label}: potrebbe non partire")
            }

            var range = 5
            val screen = preferences.capabilities.hdrFormats
            val shown = if (screen == null) info.hdr else info.hdr.filter { it in screen || (it == HdrFormat.HDR10_PLUS && HdrFormat.HDR10 in screen) || (it == HdrFormat.DOLBY_VISION && HdrFormat.HDR10 in screen) }
            if (screen != null && info.hdr.isNotEmpty() && shown.isEmpty()) { range = 3; bad("Lo schermo non mostra l'HDR: colori convertiti") }
            else if (HdrFormat.DOLBY_VISION in shown && (screen == null || HdrFormat.DOLBY_VISION in screen)) { range = 10; good("Dolby Vision (nel nome)") }
            else if (shown.isNotEmpty()) { range = 9; good("${shown.first().label} (nel nome)") }

            var sound = 5
            if (AudioCodec.ATMOS in info.audio || AudioCodec.TRUEHD in info.audio) {
                sound = 10; good("Audio ${if (AudioCodec.ATMOS in info.audio) "Dolby Atmos" else "TrueHD"}")
            } else if (AudioCodec.EAC3 in info.audio || AudioCodec.DTS in info.audio || AudioCodec.AC3 in info.audio) {
                sound = 8; good("Audio multicanale")
            }

            var total = quality + language + codec + range + sound
            if (info.warnings.isNotEmpty()) {
                total -= minOf(15, info.warnings.size * 5); bad(info.warnings.first())
            }
            if (info.needsHeaders) total -= 3
            return SourceRating(total.coerceIn(0, 100), reasons)
        }
    }
}
