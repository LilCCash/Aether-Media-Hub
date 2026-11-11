package app.aether.core.playback

/** One subtitle line with the time span it is on screen. */
data class TimedCue(val startMs: Long, val endMs: Long, val text: String)

/** Reads SubRip (.srt) and WebVTT (.vtt) files, so the app can show, delay and *anticipate* addon subtitles by itself. */
object SubtitleParser {
    private val time = Regex("""(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})""")
    private val arrow = Regex("""(\S+)\s*-->\s*(\S+)""")
    private val tags = Regex("""<[^>]*>|\{\\[^}]*}""")

    /** Decodes UTF-8 and, when that is not valid text (old SRT files), Windows-1252. */
    fun decode(bytes: ByteArray): String {
        val start = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) 3 else 0
        val utf8 = String(bytes, start, bytes.size - start, Charsets.UTF_8)
        return if ('�' in utf8) String(bytes, start, bytes.size - start, charset("windows-1252")) else utf8
    }

    fun parse(text: String): List<TimedCue> {
        val cues = ArrayList<TimedCue>()
        for (block in text.replace("\r\n", "\n").replace('\r', '\n').split(Regex("\n{2,}"))) {
            val lines = block.split('\n')
            val at = lines.indexOfFirst { "-->" in it }
            if (at < 0) continue
            val match = arrow.find(lines[at]) ?: continue
            val start = millis(match.groupValues[1]) ?: continue
            val end = millis(match.groupValues[2]) ?: continue
            val body = lines.drop(at + 1).joinToString("\n") { it.replace(tags, "").trim() }.trim()
            if (body.isNotEmpty() && end > start) cues.add(TimedCue(start, end, body))
        }
        return cues.sortedBy { it.startMs }
    }

    private fun millis(value: String): Long? {
        val m = time.matchEntire(value) ?: return null
        val (h, min, s, frac) = m.destructured
        val ms = frac.padEnd(3, '0').take(3).toLong()
        return (h.ifEmpty { "0" }.toLong() * 3600 + min.toLong() * 60 + s.toLong()) * 1000 + ms
    }

    /** The cues on screen at [positionMs] once the subtitles are shifted by [offsetMs] (positive = later, negative = earlier). */
    fun active(cues: List<TimedCue>, positionMs: Long, offsetMs: Long): List<TimedCue> {
        val t = positionMs - offsetMs
        return cues.filter { it.startMs <= t && t < it.endMs }
    }
}
