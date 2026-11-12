package app.aether.tv

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Display
import app.aether.core.playback.HdrFormat
import app.aether.core.playback.VideoCodec

/** What this TV can decode and show, read once from the system codecs and the display (no guess when the system does not say). */
object DeviceCapabilities {
    @Volatile private var decoders: Set<VideoCodec>? = null
    @Volatile private var hdr: Set<HdrFormat>? = null

    fun decoders(): Set<VideoCodec> = decoders ?: runCatching {
        val mimes = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }.flatMap { it.supportedTypes.toList() }.map { it.lowercase() }.toSet()
        buildSet {
            if (MediaFormat.MIMETYPE_VIDEO_AVC in mimes) add(VideoCodec.H264)
            if (MediaFormat.MIMETYPE_VIDEO_HEVC in mimes) add(VideoCodec.HEVC)
            if ("video/av01" in mimes) add(VideoCodec.AV1)
            if (MediaFormat.MIMETYPE_VIDEO_VP9 in mimes) add(VideoCodec.VP9)
            if (MediaFormat.MIMETYPE_VIDEO_MPEG2 in mimes) add(VideoCodec.MPEG2)
            if (MediaFormat.MIMETYPE_VIDEO_MPEG4 in mimes) add(VideoCodec.XVID)
        }
    }.getOrDefault(emptySet()).also { decoders = it }

    @Suppress("DEPRECATION")
    fun hdrFormats(context: Context): Set<HdrFormat> = hdr ?: runCatching {
        val display = context.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val types = display?.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
        buildSet {
            for (type in types) when (type) {
                Display.HdrCapabilities.HDR_TYPE_HDR10 -> add(HdrFormat.HDR10)
                Display.HdrCapabilities.HDR_TYPE_HLG -> add(HdrFormat.HLG)
                Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> add(HdrFormat.DOLBY_VISION)
                else -> if (Build.VERSION.SDK_INT >= 29 && type == Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS) add(HdrFormat.HDR10_PLUS)
            }
        }
    }.getOrDefault(emptySet()).also { hdr = it }

    fun summary(context: Context): String {
        val d = decoders().joinToString(", ") { it.label }.ifEmpty { "nessuno rilevato" }
        val h = hdrFormats(context).joinToString(", ") { it.label }.ifEmpty { "nessuno (SDR)" }
        return "Decoder video: $d · HDR dello schermo: $h"
    }
}
