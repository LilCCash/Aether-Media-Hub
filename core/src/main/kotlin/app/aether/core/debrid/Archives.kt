package app.aether.core.debrid

import java.util.concurrent.ConcurrentHashMap

/** Reads a range of bytes (both ends included) of a remote file. */
typealias RangeFetch = suspend (LongRange) -> ByteArray

class ArchiveError(message: String) : Exception(message)

private fun u16(b: ByteArray, at: Int): Int = if (at < 0 || at + 2 > b.size) 0 else (b[at].toInt() and 0xFF) or ((b[at + 1].toInt() and 0xFF) shl 8)
private fun u32(b: ByteArray, at: Int): Long = if (at < 0 || at + 4 > b.size) 0 else
    (b[at].toLong() and 0xFF) or ((b[at + 1].toLong() and 0xFF) shl 8) or ((b[at + 2].toLong() and 0xFF) shl 16) or ((b[at + 3].toLong() and 0xFF) shl 24)
private fun u64(b: ByteArray, at: Int): Long = u32(b, at) or (u32(b, at + 4) shl 32)

/**
 * The index of a ZIP read through ranged reads (its end, then the central directory), without downloading it: a torrent that is one
 * big ZIP of episodes can then play one of them. An entry stored without compression (what packers do with video) is a plain run of
 * bytes inside the ZIP, so it plays like a file of its own. Same rules as the iPhone.
 */
object ZipArchive {
    data class Entry(val name: String, val method: Int, val flags: Int, val compressedSize: Long, val uncompressedSize: Long, val localHeaderOffset: Long) {
        val isStored: Boolean get() = method == 0
        val isEncrypted: Boolean get() = flags and 1 != 0
        val isDirectory: Boolean get() = name.endsWith("/")
    }

    suspend fun entries(total: Long, fetch: RangeFetch): List<Entry> {
        if (total < 22) throw ArchiveError("non è uno ZIP")
        val tailLength = minOf(total, 65_535L + 22 + 20)
        val tailStart = total - tailLength
        val tail = fetch(tailStart..total - 1)
        var eocd = -1
        for (p in tail.size - 22 downTo 0) if (tail[p] == 0x50.toByte() && tail[p + 1] == 0x4b.toByte() && tail[p + 2] == 0x05.toByte() && tail[p + 3] == 0x06.toByte()) { eocd = p; break }
        if (eocd < 0) throw ArchiveError("non è uno ZIP")
        val count = u16(tail, eocd + 10)
        var size = u32(tail, eocd + 12)
        var offset = u32(tail, eocd + 16)
        var zip64 = count == 0xFFFF || size == 0xFFFF_FFFFL || offset == 0xFFFF_FFFFL
        var recordOffset: Long? = null
        if (eocd >= 20 && u32(tail, eocd - 20) == 0x07064b50L) { recordOffset = u64(tail, eocd - 12); zip64 = true }
        if (zip64 && recordOffset != null) {
            val record = if (recordOffset >= tailStart && recordOffset + 56 <= total) tail.copyOfRange((recordOffset - tailStart).toInt(), minOf(tail.size, (recordOffset - tailStart).toInt() + 56))
            else fetch(recordOffset..minOf(total - 1, recordOffset + 55))
            if (record.size < 56 || u32(record, 0) != 0x06064b50L) throw ArchiveError("ZIP64 non leggibile")
            size = u64(record, 40); offset = u64(record, 48)
        }
        if (size <= 0 || offset < 0 || offset + size > total) throw ArchiveError("ZIP troncato")
        if (size > 64L shl 20) throw ArchiveError("indice dello ZIP troppo grande")
        return parseDirectory(fetch(offset until offset + size))
    }

    fun parseDirectory(data: ByteArray): List<Entry> {
        val result = ArrayList<Entry>()
        var p = 0
        while (p + 46 <= data.size && u32(data, p) == 0x02014b50L) {
            val flags = u16(data, p + 8)
            val method = u16(data, p + 10)
            var compressed = u32(data, p + 20)
            var uncompressed = u32(data, p + 24)
            val nameLength = u16(data, p + 28)
            val extraLength = u16(data, p + 30)
            val commentLength = u16(data, p + 32)
            var local = u32(data, p + 42)
            val nameStart = p + 46
            if (nameStart + nameLength + extraLength > data.size) break
            val name = String(data, nameStart, nameLength, Charsets.UTF_8)
            var extra = nameStart + nameLength
            val extraEnd = extra + extraLength
            while (extra + 4 <= extraEnd) {
                val tag = u16(data, extra)
                val len = u16(data, extra + 2)
                if (tag == 1) {
                    var field = extra + 4
                    val end = extra + 4 + len
                    if (uncompressed == 0xFFFF_FFFFL && field + 8 <= end) { uncompressed = u64(data, field); field += 8 }
                    if (compressed == 0xFFFF_FFFFL && field + 8 <= end) { compressed = u64(data, field); field += 8 }
                    if (local == 0xFFFF_FFFFL && field + 8 <= end) local = u64(data, field)
                }
                extra += 4 + len
            }
            result += Entry(name, method, flags, compressed, uncompressed, local)
            p = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    /** Where the bytes of [entry] start (after its local header, whose extra field can differ from the central one). */
    suspend fun window(entry: Entry, total: Long, fetch: RangeFetch): Pair<Long, Long> {
        if (entry.localHeaderOffset + 30 > total) throw ArchiveError("ZIP troncato")
        val h = fetch(entry.localHeaderOffset..entry.localHeaderOffset + 29)
        if (h.size < 30 || u32(h, 0) != 0x04034b50L) throw ArchiveError("ZIP troncato")
        val offset = entry.localHeaderOffset + 30 + u16(h, 26) + u16(h, 28)
        val length = if (entry.isStored) entry.uncompressedSize else entry.compressedSize
        if (offset + length > total) throw ArchiveError("ZIP troncato")
        return offset to length
    }
}

/**
 * The file headers of a RAR (version 4 or 5) read through ranged reads, so a video stored in it without compression (scene packs,
 * often split over volumes: `.part01.rar…`, `.rar/.r00…`) plays from inside it. A RAR has no index: the headers are walked in order.
 */
object RarArchive {
    data class Entry(
        val name: String, val packedSize: Long, val unpackedSize: Long, val dataOffset: Long, val isStored: Boolean, val isEncrypted: Boolean,
        val continuesFromPrevious: Boolean, val continuesInNext: Boolean, val isDirectory: Boolean,
    )

    private val sig4 = byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00)
    private val sig5 = byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00)
    private const val CHUNK = 64L * 1024

    suspend fun entries(total: Long, fetch: RangeFetch, firstFileOnly: Boolean = false, limit: Int = 400): List<Entry> {
        var buffer = fetch(0..minOf(total - 1, CHUNK - 1))
        var bufferStart = 0L
        val five = buffer.size >= 8 && buffer.copyOfRange(0, 8).contentEquals(sig5)
        if (!five && !(buffer.size >= 7 && buffer.copyOfRange(0, 7).contentEquals(sig4))) throw ArchiveError("non è un RAR")
        var position = if (five) 8L else 7L
        val result = ArrayList<Entry>()
        var headers = 0
        suspend fun ensure(length: Int): ByteArray? {
            if (position < bufferStart || position + length > bufferStart + buffer.size) {
                if (position >= total) return null
                buffer = fetch(position..minOf(total - 1, position + maxOf(CHUNK, length.toLong()) - 1))
                bufferStart = position
            }
            val start = (position - bufferStart).toInt()
            return if (start + length <= buffer.size) buffer.copyOfRange(start, start + length) else null
        }
        while (position < total) {
            if (++headers > limit * 4) throw ArchiveError("troppi file nel RAR")
            if (five) {
                val peek = ensure(minOf((total - position).toInt(), 14)) ?: break
                val c = intArrayOf(4)
                val headerSize = vint(peek, c) ?: throw ArchiveError("RAR troncato")
                val headerTotal = c[0] + headerSize.toInt()
                if (headerSize <= 0 || headerSize >= (2 shl 20)) throw ArchiveError("RAR troncato")
                val block = ensure(headerTotal) ?: throw ArchiveError("RAR troncato")
                val parsed = parseHeader5(block, c[0]) ?: throw ArchiveError("RAR troncato")
                val dataStart = position + headerTotal
                if (parsed.first == 4L) throw ArchiveError("il RAR è cifrato")
                if (parsed.first == 5L) break
                parsed.third?.let { e -> result += e.copy(dataOffset = dataStart); if (firstFileOnly || result.size >= limit) return result }
                position = dataStart + parsed.second
            } else {
                val common = ensure(minOf((total - position).toInt(), 7)) ?: break
                if (common.size < 7) break
                val type = common[2].toInt() and 0xFF
                val flags = u16(common, 3)
                val headSize = u16(common, 5)
                if (headSize < 7) throw ArchiveError("RAR troncato")
                val block = ensure(headSize) ?: throw ArchiveError("RAR troncato")
                var dataSize = if (flags and 0x8000 != 0 && headSize >= 11) u32(block, 7) else 0L
                if (type == 0x7B) break
                if (type == 0x73 && flags and 0x0080 != 0) throw ArchiveError("il RAR è cifrato")
                if (type == 0x74) {
                    if (flags and 0x100 != 0 && headSize >= 36) dataSize = dataSize or (u32(block, 32) shl 32)
                    parseFileHeader4(block, flags)?.let { e -> result += e.copy(dataOffset = position + headSize, packedSize = dataSize); if (firstFileOnly || result.size >= limit) return result }
                }
                position += headSize + dataSize
            }
        }
        return result
    }

    private fun parseFileHeader4(block: ByteArray, flags: Int): Entry? {
        if (block.size < 32) return null
        var unpacked = u32(block, 11)
        val method = block[25].toInt() and 0xFF
        val nameSize = u16(block, 26)
        var nameStart = 32
        if (flags and 0x100 != 0) { if (block.size < 40) return null; unpacked = unpacked or (u32(block, 36) shl 32); nameStart = 40 }
        if (nameStart + nameSize > block.size) return null
        var bytes = block.copyOfRange(nameStart, nameStart + nameSize)
        bytes.indexOf(0).takeIf { it >= 0 }?.let { bytes = bytes.copyOfRange(0, it) }
        return Entry(String(bytes, Charsets.UTF_8).replace('\\', '/'), 0, unpacked, 0, method == 0x30, flags and 0x04 != 0, flags and 0x01 != 0, flags and 0x02 != 0, flags and 0xE0 == 0xE0)
    }

    /** (type, data size, file entry). */
    private fun parseHeader5(block: ByteArray, start: Int): Triple<Long, Long, Entry?>? {
        val c = intArrayOf(start)
        val type = vint(block, c) ?: return null
        val flags = vint(block, c) ?: return null
        var extraSize = 0L
        var dataSize = 0L
        if (flags and 1L != 0L) extraSize = vint(block, c) ?: return null
        if (flags and 2L != 0L) dataSize = vint(block, c) ?: return null
        if (type != 2L) return Triple(type, dataSize, null)
        val fileFlags = vint(block, c) ?: return null
        val unpacked = vint(block, c) ?: return null
        vint(block, c) ?: return null
        if (fileFlags and 2L != 0L) c[0] += 4
        if (fileFlags and 4L != 0L) c[0] += 4
        val compression = vint(block, c) ?: return null
        vint(block, c) ?: return null
        val nameLength = (vint(block, c) ?: return null).toInt()
        if (c[0] + nameLength > block.size) return null
        val name = String(block, c[0], nameLength, Charsets.UTF_8)
        c[0] += nameLength
        var encrypted = false
        val e = intArrayOf(c[0])
        val extraEnd = minOf(block.size, c[0] + extraSize.toInt())
        while (e[0] < extraEnd) {
            val size = vint(block, e) ?: break
            val recordEnd = e[0] + size.toInt()
            val recordType = vint(block, e) ?: break
            if (recordType == 1L) encrypted = true
            e[0] = recordEnd
        }
        val method = (compression shr 7) and 0x7
        return Triple(type, dataSize, Entry(name, dataSize, unpacked, 0, method == 0L, encrypted, flags and 0x08L != 0L, flags and 0x10L != 0L, fileFlags and 1L != 0L))
    }

    internal fun vint(data: ByteArray, cursor: IntArray): Long? {
        var value = 0L
        var shift = 0
        while (cursor[0] < data.size && shift < 64) {
            val b = data[cursor[0]++].toInt() and 0xFF
            value = value or ((b and 0x7F).toLong() shl shift)
            if (b and 0x80 == 0) return value
            shift += 7
        }
        return null
    }

    /** The volumes grouped by set, each in reading order: `name.part1.rar, name.part2.rar…` or `name.rar, name.r00, name.r01…`. */
    fun volumeSets(names: List<String>): List<List<String>> {
        data class V(val name: String, val base: String, val order: Int)
        val part = Regex("""\.part(\d+)\.rar$""")
        val old = Regex("""\.r(\d{2,3})$""")
        val volumes = names.mapNotNull { name ->
            val lower = name.lowercase()
            part.find(lower)?.let { return@mapNotNull V(name, lower.substring(0, it.range.first), it.groupValues[1].toInt()) }
            if (lower.endsWith(".rar")) return@mapNotNull V(name, lower.dropLast(4), -1)
            old.find(lower)?.let { V(name, lower.substring(0, it.range.first), it.groupValues[1].toInt()) }
        }
        return volumes.groupBy { it.base }.toSortedMap().values.map { set -> set.sortedBy { it.order }.map { it.name } }
    }
}

/** A video inside an archive: the runs of bytes, in order, of the links it is made of. */
data class ArchiveVideo(val name: String, val pieces: List<Piece>) {
    data class Piece(val url: String, val offset: Long, val length: Long)
    val length: Long get() = pieces.sumOf { it.length }
}

/**
 * The videos read from inside archives, by token: the player opens `aether-archive://<token>` and reads the pieces with ranged
 * requests. The links (they may carry the account key) stay in memory only.
 */
object ArchiveRegistry {
    const val SCHEME = "aether-archive"
    private val videos = ConcurrentHashMap<String, ArchiveVideo>()

    fun register(video: ArchiveVideo): String {
        val token = java.util.UUID.randomUUID().toString().replace("-", "")
        if (videos.size > 20) videos.keys.take(videos.size - 20).forEach { videos.remove(it) }
        videos[token] = video
        val ext = video.name.substringAfterLast('.', "mkv").lowercase().filter { it.isLetterOrDigit() }.take(4)
        return "$SCHEME://$token/video.$ext"
    }

    fun video(url: String): ArchiveVideo? = if (!url.startsWith("$SCHEME://")) null else videos[url.removePrefix("$SCHEME://").substringBefore('/')]
}

/** Finds the wanted video in a ZIP or in a set of RAR volumes and says where its bytes are. */
object ArchiveLocator {
    data class Part(val url: String, val name: String, val size: Long)

    suspend fun locate(parts: List<Part>, wanted: (List<DebridFile>) -> DebridFile?, fetchFor: (String) -> RangeFetch): ArchiveVideo {
        val first = parts.firstOrNull() ?: throw DebridError.ArchivesOnly
        if (first.name.lowercase().endsWith(".zip")) {
            val fetch = fetchFor(first.url)
            val entries = ZipArchive.entries(first.size, fetch)
            val videos = entries.withIndex().filter { (_, e) -> !e.isDirectory && !e.isEncrypted && TorBoxFileMatcher.isVideo(DebridFile(0, e.name, e.name.substringAfterLast('/'), e.uncompressedSize, null, false, false)) }
            val files = videos.map { (i, e) -> DebridFile(i, e.name, e.name.substringAfterLast('/'), e.uncompressedSize, null, false, false) }
            val pick = (if (files.size == 1) files.first() else wanted(files)) ?: throw DebridError.NoVideo
            val entry = entries[pick.id]
            if (!entry.isStored) throw ArchiveError("«${pick.shortName}» è compresso nello ZIP: non si può leggere a pezzi")
            val (offset, length) = ZipArchive.window(entry, first.size, fetch)
            return ArchiveVideo(pick.shortName, listOf(ArchiveVideo.Piece(first.url, offset, length)))
        }
        val firstFetch = fetchFor(first.url)
        val entries = RarArchive.entries(first.size, firstFetch, firstFileOnly = parts.size > 1)
        val videos = entries.filter { !it.isDirectory && TorBoxFileMatcher.isVideo(DebridFile(0, it.name, it.name.substringAfterLast('/'), it.unpackedSize, null, false, false)) }
        val files = videos.mapIndexed { i, e -> DebridFile(i, e.name, e.name.substringAfterLast('/'), e.unpackedSize, null, false, false) }
        val pick = (if (files.size == 1) files.first() else wanted(files)) ?: throw DebridError.NoVideo
        val entry = videos[pick.id]
        if (!entry.isStored || entry.isEncrypted) throw ArchiveError("«${pick.shortName}» è ${if (entry.isEncrypted) "cifrato" else "compresso"} nel RAR: non si può leggere a pezzi")
        val pieces = arrayListOf(ArchiveVideo.Piece(first.url, entry.dataOffset, entry.packedSize))
        var continues = entry.continuesInNext
        var index = 1
        while (continues && index < parts.size) {
            val next = RarArchive.entries(parts[index].size, fetchFor(parts[index].url), firstFileOnly = true).firstOrNull()
            if (next == null || next.name != entry.name || !next.continuesFromPrevious) throw ArchiveError("il volume ${index + 1} non continua il video")
            pieces += ArchiveVideo.Piece(parts[index].url, next.dataOffset, next.packedSize)
            continues = next.continuesInNext
            index++
        }
        if (continues || pieces.sumOf { it.length } != entry.unpackedSize) throw ArchiveError("il video nel RAR è incompleto")
        return ArchiveVideo(pick.shortName, pieces)
    }
}
