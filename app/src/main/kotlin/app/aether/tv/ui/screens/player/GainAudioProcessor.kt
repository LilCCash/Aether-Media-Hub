package app.aether.tv.ui.screens.player

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sign
import kotlin.math.tanh

/**
 * Raises the volume of the decoded audio above what the TV's own volume allows. It works on the PCM that ExoPlayer hands to the
 * audio track (16-bit or float) with a soft limiter, so loud peaks are rounded off instead of cracking. It cannot touch audio that
 * is sent untouched to an amplifier (Dolby / DTS passthrough): the player avoids passthrough when a gain is set.
 */
@UnstableApi
class GainAudioProcessor : BaseAudioProcessor() {
    @Volatile private var factor = 1f

    fun setGainDb(db: Int) { factor = 10.0.pow(db.coerceIn(0, 18) / 20.0).toFloat() }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat =
        if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT || inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) inputAudioFormat
        else AudioProcessor.AudioFormat.NOT_SET

    override fun queueInput(inputBuffer: ByteBuffer) {
        val size = inputBuffer.remaining()
        if (size == 0) return
        val out = replaceOutputBuffer(size)
        val g = factor
        val input = inputBuffer.order(ByteOrder.nativeOrder())
        if (g == 1f) {
            out.put(input)
        } else if (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) {
            while (input.remaining() >= 4) out.putFloat(limit(input.getFloat() * g))
        } else {
            while (input.remaining() >= 2) out.putShort((limit(input.getShort() / 32768f * g) * 32767f).toInt().coerceIn(-32768, 32767).toShort())
        }
        out.flip()
    }

    private fun limit(x: Float): Float {
        val a = abs(x)
        return if (a <= KNEE) x else sign(x) * (KNEE + (1f - KNEE) * tanh((a - KNEE) / (1f - KNEE)))
    }

    private companion object { const val KNEE = 0.8f }
}
