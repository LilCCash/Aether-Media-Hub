package app.aether.core.playback

/** One line (or block of lines) of a subtitle file, with when it shows. */
data class TimedCue(val startMs: Long, val endMs: Long, val text: String)

/**
 * Reads the subtitle files the addons and OpenSubtitles hand out — SubRip (.srt), WebVTT (.vtt), Advanced SubStation (.ass/.ssa) and
 * MicroDVD (.sub) — so the app can show, delay and *anticipate* them by itself. Files compressed with gzip or ZIP are opened first.
 */
object SubtitleParser {
    private val time = Regex("""(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[.,:](\d{1,3}))?""")
    private val arrow = Regex("""^\s*(\S+)\s*-->\s*(\S+)""")
    private val tags = Regex("""<[^>]*>|\{\\[^}]*}""")
    private val microDvd = Regex("""^\{(\d+)\}\{(\d+)\}(.*)$""")

    /** The text of a subtitle file: unpacks gzip and ZIP, then UTF-8 (with or without BOM), UTF-16 or, for old files, Windows-1252. */
    fun decode(raw: ByteArray): String {
        val bytes = unpack(raw)
        if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
        if (bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()) return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
        val start = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) 3 else 0
        val utf8 = String(bytes, start, bytes.size - start, Charsets.UTF_8)
        return if ('�' in utf8) String(bytes, start, bytes.size - start, charset("windows-1252")) else utf8
    }

    /** gzip (OpenSubtitles.org hands out `.gz`) and ZIP (the first subtitle file inside) are opened; anything else comes back as is. */
    fun unpack(bytes: ByteArray, limit: Int = 16 shl 20): ByteArray {
        try {
            if (bytes.size > 18 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte()) {
                return java.util.zip.GZIPInputStream(bytes.inputStream()).use { readCapped(it, limit) }
            }
            if (bytes.size > 30 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte() && bytes[2] == 3.toByte() && bytes[3] == 4.toByte()) {
                java.util.zip.ZipInputStream(bytes.inputStream()).use { zip ->
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        val ext = entry.name.substringAfterLast('.', "").lowercase()
                        if (!entry.isDirectory && ext in setOf("srt", "vtt", "ass", "ssa", "sub", "txt")) return readCapped(zip, limit)
                    }
                }
            }
        } catch (_: java.io.IOException) {
            return bytes
        }
        return bytes
    }

    private fun readCapped(input: java.io.InputStream, limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            if (out.size() > limit) throw java.io.IOException("subtitle too large")
        }
        return out.toByteArray()
    }

    fun parse(text: String): List<TimedCue> {
        val clean = text.replace("\r\n", "\n").replace('\r', '\n')
        val head = clean.trimStart().take(400)
        val cues = when {
            head.startsWith("[Script Info]", ignoreCase = true) || Regex("""(?m)^\s*Dialogue\s*:""").containsMatchIn(clean.take(20_000)) && "-->" !in head -> parseAss(clean)
            microDvd.containsMatchIn(head.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty()) -> parseMicroDvd(clean)
            else -> parseTimed(clean)
        }
        return cues.sortedBy { it.startMs }
    }

    /** SubRip and WebVTT, line by line: a timing line opens a cue, a blank line (even with spaces in it) or the next timing closes it. */
    private fun parseTimed(text: String): List<TimedCue> {
        val cues = ArrayList<TimedCue>()
        val lines = text.split('\n')
        var start = -1L
        var end = -1L
        val body = ArrayList<String>()
        fun close() {
            // A bare number right before the next timing line is the index of the next cue, not text.
            while (body.isNotEmpty() && body.last().trim().all { it.isDigit() }) body.removeAt(body.size - 1)
            val content = body.joinToString("\n") { it.replace(tags, "").trim() }.trim()
            if (start >= 0 && content.isNotEmpty() && end > start) cues.add(TimedCue(start, end, content))
            start = -1; end = -1; body.clear()
        }
        for (line in lines) {
            val match = arrow.find(line)
            if (match != null) {
                val s = millis(match.groupValues[1])
                val e = millis(match.groupValues[2])
                if (s != null && e != null) { close(); start = s; end = e; continue }
            }
            if (start < 0) continue
            if (line.isBlank()) close() else body.add(line)
        }
        close()
        return cues
    }

    /** `Dialogue: 0,0:00:01.50,0:00:04.00,Default,,0,0,0,,Text` — the text is the tenth field; `\N` is a line break. */
    private fun parseAss(text: String): List<TimedCue> {
        val cues = ArrayList<TimedCue>()
        var textField = 9
        var startField = 1
        var endField = 2
        for (line in text.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.startsWith("Format:", ignoreCase = true) && cues.isEmpty()) {
                val fields = trimmed.substringAfter(':').split(',').map { it.trim().lowercase() }
                if ("text" in fields) { textField = fields.indexOf("text"); startField = fields.indexOf("start").coerceAtLeast(0); endField = fields.indexOf("end").coerceAtLeast(0) }
                continue
            }
            if (!trimmed.startsWith("Dialogue:", ignoreCase = true)) continue
            val parts = trimmed.substringAfter(':').split(',', limit = textField + 1)
            if (parts.size <= textField) continue
            val s = millis(parts[startField].trim()) ?: continue
            val e = millis(parts[endField].trim()) ?: continue
            val content = parts[textField].replace(Regex("""\{[^}]*}"""), "").replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " ").trim()
            if (content.isNotEmpty() && e > s) cues.add(TimedCue(s, e, content))
        }
        return cues
    }

    /** `{100}{200}Text|Second line`, in frames: the first cue may state the frame rate (`{1}{1}23.976`), else 23.976. */
    private fun parseMicroDvd(text: String): List<TimedCue> {
        val cues = ArrayList<TimedCue>()
        var fps = 23.976
        for (line in text.lineSequence()) {
            val m = microDvd.find(line.trim()) ?: continue
            val (a, b, body) = m.destructured
            if (a == "1" && b == "1" && body.trim().toDoubleOrNull() != null) { fps = body.trim().toDouble(); continue }
            val content = body.replace(Regex("""\{[^}]*}"""), "").replace('|', '\n').trim()
            val s = (a.toLong() * 1000 / fps).toLong()
            val e = (b.toLong() * 1000 / fps).toLong()
            if (content.isNotEmpty() && e > s) cues.add(TimedCue(s, e, content))
        }
        return cues
    }

    private fun millis(value: String): Long? {
        val m = time.matchEntire(value.trim()) ?: return null
        val (h, min, s, frac) = m.destructured
        // ASS writes hundredths (0:00:01.50 = 1.5 s): the fraction is read as a decimal.
        val ms = if (frac.isEmpty()) 0 else frac.padEnd(3, '0').take(3).toLong()
        return (h.ifEmpty { "0" }.toLong() * 3600 + min.toLong() * 60 + s.toLong()) * 1000 + ms
    }

    /** Writes cues as SubRip (what the saved subtitles of a download are). */
    fun toSrt(cues: List<TimedCue>): String = buildString {
        fun t(ms: Long) = "%02d:%02d:%02d,%03d".format(ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        cues.forEachIndexed { i, c -> append(i + 1).append('\n').append(t(c.startMs)).append(" --> ").append(t(c.endMs)).append('\n').append(c.text).append("\n\n") }
    }

    /** The cues on screen at [positionMs] once the subtitles are shifted by [offsetMs] (positive = later, negative = earlier). */
    fun active(cues: List<TimedCue>, positionMs: Long, offsetMs: Long): List<TimedCue> {
        val t = positionMs - offsetMs
        return cues.filter { it.startMs <= t && t < it.endMs }
    }
}
