import Foundation

// The FFmpeg libraries ship inside MPVKit (LGPL build). The remuxer talks to them directly; this file only says whether they can be
// imported in this build, so the rest of the app (and the tests) can ask instead of guessing.
#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
import Libavformat
import Libavcodec
import Libavutil

enum FFmpegAvailability {
    static let isLinked = true

    /// "major.minor.micro" of libavformat, as the library itself reports it.
    static var libavformatVersion: String {
        let packed = avformat_version()
        return "\(packed >> 16).\((packed >> 8) & 0xff).\(packed & 0xff)"
    }

    static var libavformatMajor: Int { return Int(avformat_version() >> 16) }
}
#else
#error("FFmpeg (Libavformat) non è collegato: il remux non funzionerebbe")
enum FFmpegAvailability {
    static let isLinked = false
    static var libavformatVersion: String { return "non collegata" }
    static var libavformatMajor: Int { return 0 }
}
#endif
