package app.aether.core.livetv

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.text.Normalizer
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.TimeZone
import java.util.zip.GZIPInputStream
import javax.xml.parsers.SAXParserFactory
import kotlinx.serialization.Serializable
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler

/** One programme of the TV guide; times in epoch milliseconds. */
@Serializable
data class TvProgramme(val start: Long, val stop: Long, val title: String, val subtitle: String? = null, val summary: String? = null, val category: String? = null) {
    fun isOn(at: Long) = at in start until stop

    /** 0…1, how much of the programme has gone by. */
    fun progress(at: Long): Double {
        val length = stop - start
        return if (length <= 0) 0.0 else ((at - start).toDouble() / length).coerceIn(0.0, 1.0)
    }
}

/** A TV guide (XMLTV): the channels it knows, with their names, and their programmes in order. */
@Serializable
data class TvGuide(
    val channels: List<Channel> = emptyList(),
    /** Guide channel id → programmes, by start time. */
    val programmes: Map<String, List<TvProgramme>> = emptyMap(),
    val fetchedAt: Long = System.currentTimeMillis(),
) {
    @Serializable
    data class Channel(val id: String, val names: List<String>)

    val isEmpty: Boolean get() = programmes.isEmpty()

    fun now(channelId: String, at: Long = System.currentTimeMillis()) = programmes[channelId]?.firstOrNull { it.isOn(at) }

    fun upcoming(channelId: String, from: Long = System.currentTimeMillis(), count: Int): List<TvProgramme> =
        programmes[channelId].orEmpty().asSequence().filter { it.stop > from }.take(count).toList()

    fun between(channelId: String, start: Long, end: Long) = programmes[channelId].orEmpty().filter { it.stop > start && it.start < end }

    companion object {
        /** Italian channels, from the public guide built from Sky's listings by epgshare01 (gzip, about 2 MB, refreshed every day). */
        const val DEFAULT_ITALIAN_URL = "https://epgshare01.online/epgshare01/epg_ripper_IT1.xml.gz"
    }
}

/** Reads an XMLTV file (plain or gzip), keeping only the programmes that touch a window around now. */
object XmltvParser {
    fun parse(bytes: ByteArray, now: Long = System.currentTimeMillis(), keepBeforeMs: Long = 3 * 3_600_000L, keepAfterMs: Long = 36 * 3_600_000L): TvGuide =
        parse(if (isGzip(bytes)) GZIPInputStream(ByteArrayInputStream(bytes), 64 * 1024) else ByteArrayInputStream(bytes), now, keepBeforeMs, keepAfterMs)

    fun parse(input: InputStream, now: Long = System.currentTimeMillis(), keepBeforeMs: Long = 3 * 3_600_000L, keepAfterMs: Long = 36 * 3_600_000L): TvGuide {
        val handler = Handler(now - keepBeforeMs, now + keepAfterMs)
        val factory = SAXParserFactory.newInstance()
        runCatching { factory.setFeature("http://xml.org/sax/features/external-general-entities", false) }
        runCatching { factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
        runCatching { factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
        val parser = factory.newSAXParser()
        val reader = parser.xmlReader
        reader.setEntityResolver { _, _ -> InputSource(ByteArrayInputStream(ByteArray(0))) }
        reader.contentHandler = handler
        try { reader.parse(InputSource(input)) } catch (_: Exception) { /* a truncated file keeps what was read */ }
        val programmes = handler.programmes.mapValues { (_, list) ->
            val seen = HashSet<Long>()
            list.sortedBy { it.start }.filter { seen.add(it.start) }
        }
        return TvGuide(handler.channels, programmes, now)
    }

    fun isGzip(bytes: ByteArray) = bytes.size > 18 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte()

    /** `20261108050000 +0000` (the offset may be missing: then UTC). */
    fun date(text: String): Long? {
        val parts = text.trim().split(' ').filter { it.isNotEmpty() }
        val stamp = parts.firstOrNull() ?: return null
        if (stamp.length < 12 || !stamp.take(14).all { it.isDigit() }) return null
        fun n(from: Int, len: Int) = if (from + len <= stamp.length) stamp.substring(from, from + len).toInt() else 0
        var offset = 0
        parts.getOrNull(1)?.let { zone ->
            if (zone.length == 5 && (zone[0] == '+' || zone[0] == '-')) {
                val h = zone.substring(1, 3).toIntOrNull(); val m = zone.substring(3, 5).toIntOrNull()
                if (h != null && m != null) offset = (h * 3600 + m * 60) * if (zone[0] == '-') -1 else 1
            }
        }
        val calendar = GregorianCalendar(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(n(0, 4), n(4, 2) - 1, n(6, 2), n(8, 2), n(10, 2), n(12, 2))
        }
        return calendar.timeInMillis - offset * 1000L
    }

    private class Handler(val from: Long, val to: Long) : DefaultHandler() {
        val channels = ArrayList<TvGuide.Channel>()
        val programmes = HashMap<String, MutableList<TvProgramme>>()
        private var channelId: String? = null
        private val names = ArrayList<String>()
        private var programme: Triple<String, Long, Long>? = null
        private var title: String? = null
        private var subtitle: String? = null
        private var summary: String? = null
        private var category: String? = null
        private val text = StringBuilder()

        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            text.setLength(0)
            when (qName) {
                "channel" -> { channelId = attributes.getValue("id"); names.clear() }
                "programme" -> {
                    val channel = attributes.getValue("channel")
                    val start = attributes.getValue("start")?.let(::date)
                    val stop = attributes.getValue("stop")?.let(::date)
                    programme = if (channel != null && start != null && stop != null && stop > from && start < to && stop > start) Triple(channel, start, stop) else null
                    title = null; subtitle = null; summary = null; category = null
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (text.length < 2000) text.append(ch, start, length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            val value = text.toString().trim()
            text.setLength(0)
            when (qName) {
                "display-name" -> if (channelId != null && value.isNotEmpty()) names.add(value)
                "channel" -> { channelId?.let { channels.add(TvGuide.Channel(it, names.toList())) }; channelId = null }
                "title" -> if (programme != null && title == null && value.isNotEmpty()) title = value
                "sub-title" -> if (programme != null && subtitle == null && value.isNotEmpty()) subtitle = value
                "desc" -> if (programme != null && summary == null && value.isNotEmpty()) summary = value
                "category" -> if (programme != null && category == null && value.isNotEmpty()) category = value
                "programme" -> {
                    val current = programme
                    val name = title
                    if (current != null && name != null) {
                        programmes.getOrPut(current.first) { ArrayList() }.add(TvProgramme(current.second, current.third, name, subtitle, summary, category))
                    }
                    programme = null
                }
            }
        }
    }
}

/**
 * Finds the guide channel of a playlist channel: the playlist's `tvg-id` as it is, then ids and names reduced to letters and
 * digits, without «HD», «TV», the «.it» ending or the listing's channel number («Rai 1 HD  101» and «Rai1.it» are the same).
 */
class TvGuideMatcher(guide: TvGuide) {
    private val exact: Set<String> = guide.programmes.keys
    private val table: Map<String, String> = buildMap {
        for (channel in guide.channels) {
            if (guide.programmes[channel.id] == null) continue
            for (key in listOf(channel.id) + channel.names) {
                val normal = normalise(key)
                if (normal.isNotEmpty() && normal !in this) put(normal, channel.id)
            }
        }
    }

    fun channelId(tvgId: String?, name: String): String? {
        if (!tvgId.isNullOrEmpty() && tvgId in exact) return tvgId
        if (tvgId != null) table[normalise(tvgId)]?.let { return it }
        return table[normalise(name)]
    }

    companion object {
        val aliases = mapOf(
            "twentyseven" to "27twentyseven", "20mediaset" to "20", "tgcom24" to "tgcom", "raisportplus" to "raisport",
            "mediasetitalia2" to "italia2", "rtvsanmarino" to "sanmarinortv",
        )
        private val listingNumber = Regex("""(\.\.|\s\s+)\d+$""")

        fun normalise(text: String): String {
            var value = text.lowercase().trim()
            if (value.endsWith(".it")) value = value.dropLast(3)
            value = listingNumber.replace(value, "")
            value = value.replace("&", "and").replace("+", "plus")
            value = Normalizer.normalize(value, Normalizer.Form.NFD).filter { it.code < 128 && it.isLetterOrDigit() }
            while (true) {
                val ending = listOf("fhd", "uhd", "hd", "tv", "channel").firstOrNull { value.endsWith(it) && value.length > it.length + 1 } ?: break
                value = value.dropLast(ending.length)
            }
            return aliases[value] ?: value
        }
    }
}
