import Foundation

/// What the engine found out about the file, ready to be turned into playlists.
public struct RemuxPrepared: Equatable, Sendable {
    public var plan: RemuxPlan
    public var segments: [RemuxSegmentSpan]
    public var duration: Double
    public var master: HLSMasterInfo

    public init(plan: RemuxPlan, segments: [RemuxSegmentSpan], duration: Double, master: HLSMasterInfo) {
        self.plan = plan
        self.segments = segments
        self.duration = duration
        self.master = master
    }
}

public enum RemuxError: Error, Equatable, Sendable {
    /// The file has something that cannot be copied (see the refusal for what and why).
    case refused(RemuxRefusal)
    /// The container has no seek index, so it cannot be cut at keyframes without reading all of it.
    case noKeyframeIndex
    /// The container could not be opened or parsed.
    case unreadable
    /// FFmpeg reported an error; only its numeric code is kept.
    case engine(code: Int)
    case closed
    case segmentOutOfRange(Int)

    /// Italian, for the viewer.
    public var message: String {
        switch self {
        case .refused(let refusal): return refusal.message
        case .noKeyframeIndex: return "Il file non ha un indice dei fotogrammi chiave: non si può convertire al volo. Usa il motore Automatico (MPV)."
        case .unreadable: return "Non riesco a leggere questo file."
        case .engine: return "La conversione del file non è riuscita."
        case .closed: return "La conversione è stata interrotta."
        case .segmentOutOfRange: return "Parte del video non disponibile."
        }
    }
}

/// The part of the remux that needs FFmpeg. The app provides the real one; the source and the playlists around it are tested here with
/// a fake.
public protocol RemuxEngine: AnyObject, Sendable {
    /// Opens the file, looks at its tracks and keyframes, and decides what will be copied.
    func prepare() async throws -> RemuxPrepared
    /// `ftyp` + `moov`: what every media segment is decoded with.
    func initSegment() async throws -> Data
    /// `moof` + `mdat` for one segment, starting at a keyframe, with absolute decode times.
    func mediaSegment(_ index: Int) async throws -> Data
    /// Releases the file and cancels what is in flight.
    func close()
}
