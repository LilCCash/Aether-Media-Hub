package app.aether.tv.ui.screens.player

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import app.aether.core.debrid.ArchiveRegistry
import app.aether.core.debrid.ArchiveVideo
import java.io.IOException

/**
 * Plays a video stored inside a ZIP or a set of RAR volumes (`aether-archive://…`): every read is turned into ranged reads of the
 * pieces it is made of, one after the other. Any other address goes straight to the network source.
 */
@UnstableApi
class ArchiveDataSource(private val upstream: DataSource) : BaseDataSource(true) {
    class Factory(private val upstream: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource = ArchiveDataSource(upstream.createDataSource())
    }

    private var video: ArchiveVideo? = null
    private var uri: Uri? = null
    private var position = 0L
    private var remaining = 0L
    private var pieceIndex = 0
    private var pieceLeft = 0L
    private var pieceOpen = false
    private var passThrough = false


    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        if (dataSpec.uri.scheme != ArchiveRegistry.SCHEME) { passThrough = true; return upstream.open(dataSpec) }
        passThrough = false
        val v = ArchiveRegistry.video(dataSpec.uri.toString()) ?: throw IOException("Il video dell'archivio non è più disponibile: riapri la sorgente.")
        video = v
        transferInitializing(dataSpec)
        if (dataSpec.position > v.length) throw androidx.media3.datasource.DataSourceException(androidx.media3.common.PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        position = dataSpec.position
        remaining = if (dataSpec.length == C.LENGTH_UNSET.toLong()) v.length - position else minOf(dataSpec.length, v.length - position)
        openPieceAt(position)
        transferStarted(dataSpec)
        return remaining
    }

    private fun openPieceAt(at: Long) {
        val v = video!!
        if (pieceOpen) { upstream.close(); pieceOpen = false }
        var start = 0L
        for ((i, p) in v.pieces.withIndex()) {
            if (at < start + p.length) {
                val inside = at - start
                pieceIndex = i
                pieceLeft = p.length - inside
                upstream.open(DataSpec.Builder().setUri(p.url).setPosition(p.offset + inside).setLength(pieceLeft).build())
                pieceOpen = true
                return
            }
            start += p.length
        }
        pieceLeft = 0
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (passThrough) return upstream.read(buffer, offset, length)
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        if (pieceLeft == 0L) {
            if (pieceIndex + 1 >= (video?.pieces?.size ?: 0)) return C.RESULT_END_OF_INPUT
            openPieceAt(position)
        }
        val wanted = minOf(length.toLong(), remaining, pieceLeft).toInt()
        val read = upstream.read(buffer, offset, wanted)
        if (read == C.RESULT_END_OF_INPUT) { pieceLeft = 0; return if (remaining > 0 && pieceIndex + 1 < (video?.pieces?.size ?: 0)) read(buffer, offset, length) else C.RESULT_END_OF_INPUT }
        position += read; remaining -= read; pieceLeft -= read
        bytesTransferred(read)
        return read
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        if (passThrough) { upstream.close(); passThrough = false; return }
        if (pieceOpen) { upstream.close(); pieceOpen = false }
        if (video != null) { video = null; transferEnded() }
    }
}
