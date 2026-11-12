package app.aether.core

import app.aether.core.debrid.ArchiveLocator
import app.aether.core.debrid.ArchiveRegistry
import app.aether.core.debrid.ArchiveVideo
import app.aether.core.debrid.RarArchive
import app.aether.core.debrid.ZipArchive
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ArchivesTest {
    private fun storedZip(vararg files: Pair<String, ByteArray>): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        java.util.zip.ZipOutputStream(out).use { z ->
            for ((name, data) in files) {
                val e = java.util.zip.ZipEntry(name)
                e.method = java.util.zip.ZipEntry.STORED
                e.size = data.size.toLong(); e.compressedSize = data.size.toLong()
                e.crc = java.util.zip.CRC32().apply { update(data) }.value
                z.putNextEntry(e); z.write(data); z.closeEntry()
            }
        }
        return out.toByteArray()
    }

    @Test fun zipEntriesAndWindowThroughRanges() = runBlocking {
        val video = ByteArray(5000) { (it % 251).toByte() }
        val zip = storedZip("info.nfo" to "ciao".toByteArray(), "Show.S01E02.1080p.mkv" to video, "Show.S01E03.1080p.mkv" to ByteArray(10))
        var reads = 0
        val fetch: suspend (LongRange) -> ByteArray = { r -> reads++; zip.copyOfRange(r.first.toInt(), r.last.toInt() + 1) }
        val entries = ZipArchive.entries(zip.size.toLong(), fetch)
        assertEquals(3, entries.size)
        assertTrue(entries.all { it.isStored })
        val (offset, length) = ZipArchive.window(entries[1], zip.size.toLong(), fetch)
        assertEquals(video.toList(), zip.copyOfRange(offset.toInt(), (offset + length).toInt()).toList())
        assertTrue(reads <= 3)
        val located = ArchiveLocator.locate(listOf(ArchiveLocator.Part("https://x/a.zip", "a.zip", zip.size.toLong())), wanted = { files -> files.firstOrNull { "E02" in it.name } }, fetchFor = { fetch })
        assertEquals("Show.S01E02.1080p.mkv", located.name)
        assertEquals(5000L, located.length)
        val url = ArchiveRegistry.register(located)
        assertTrue(url.startsWith("aether-archive://") && url.endsWith(".mkv"))
        assertEquals(located, ArchiveRegistry.video(url))
    }

    @Test fun rarVolumeSetsAndVint() {
        assertEquals(
            listOf(listOf("a.part1.rar", "a.part2.rar", "a.part10.rar"), listOf("b.rar", "b.r00", "b.r01")),
            RarArchive.volumeSets(listOf("a.part10.rar", "b.r01", "a.part2.rar", "b.rar", "a.part1.rar", "b.r00", "readme.txt")),
        )
        assertEquals(300L, RarArchive.vint(byteArrayOf(0xAC.toByte(), 0x02), intArrayOf(0)))
    }

    @Test fun rar4StoredFile() = runBlocking {
        // A minimal RAR 4: signature, main header, one stored file header with its data, end of archive.
        val data = ByteArray(700) { (it * 7).toByte() }
        val name = "Film.2020.mkv".toByteArray()
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00))
        out.write(byteArrayOf(0, 0, 0x73, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0))
        val headSize = 32 + name.size
        fun le16(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
        fun le32(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
        out.write(byteArrayOf(0, 0, 0x74)); out.write(le16(0x8000)); out.write(le16(headSize))
        out.write(le32(data.size)); out.write(le32(data.size)); out.write(byteArrayOf(0)); out.write(le32(0)); out.write(le32(0))
        out.write(byteArrayOf(20, 0x30)); out.write(le16(name.size)); out.write(le32(0)); out.write(name)
        out.write(data)
        out.write(byteArrayOf(0, 0, 0x7B, 0, 0x40, 7, 0))
        val rar = out.toByteArray()
        val fetch: suspend (LongRange) -> ByteArray = { r -> rar.copyOfRange(r.first.toInt(), minOf(rar.size, r.last.toInt() + 1)) }
        val entries = RarArchive.entries(rar.size.toLong(), fetch)
        assertEquals(1, entries.size)
        val e = entries[0]
        assertEquals("Film.2020.mkv", e.name); assertTrue(e.isStored); assertEquals(700L, e.packedSize)
        assertEquals(data.toList(), rar.copyOfRange(e.dataOffset.toInt(), (e.dataOffset + e.packedSize).toInt()).toList())
        val located = ArchiveLocator.locate(listOf(ArchiveLocator.Part("https://x/f.rar", "f.rar", rar.size.toLong())), wanted = { null }, fetchFor = { fetch })
        assertEquals(ArchiveVideo("Film.2020.mkv", listOf(ArchiveVideo.Piece("https://x/f.rar", e.dataOffset, 700))), located)
    }
}
