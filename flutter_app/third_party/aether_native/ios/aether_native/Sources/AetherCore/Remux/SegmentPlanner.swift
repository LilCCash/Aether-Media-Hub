import Foundation

public struct RemuxSegmentSpan: Equatable, Sendable {
    public var index: Int
    /// Seconds from the start of the file.
    public var start: Double
    public var end: Double

    public init(index: Int, start: Double, end: Double) {
        self.index = index
        self.start = start
        self.end = end
    }

    public var duration: Double { return end - start }
}

public enum SegmentPlanner {
    /// Cuts the timeline at video keyframes so that every piece lasts at least `minimum` seconds, except possibly the last. A piece
    /// can only start where a player can start decoding, so a long keyframe interval gives long pieces.
    /// `opening` is a shorter minimum for the first `openingCount` pieces after the first, so playback can start on a small download.
    public static func plan(keyframes: [Double], duration: Double, minimum: Double = 6, opening: Double? = nil,
                            openingCount: Int = 3) -> [RemuxSegmentSpan] {
        guard duration > 0 else { return [] }
        let sorted = Array(Set(keyframes.filter { $0 >= 0 && $0 < duration })).sorted()
        guard !sorted.isEmpty else { return [] }
        // The first piece starts at 0, which is where the first keyframe is taken to be (the engine starts it at the first keyframe at or
        // after 0). The next piece must start a full `minimum` after the keyframe the first one really begins at, or a file whose
        // first keyframe is late would get two pieces that begin at the same keyframe.
        let first = sorted[0]
        var cuts: [Double] = [0]
        var anchor = first
        for time in sorted where time > first {
            let need = cuts.count <= openingCount ? (opening ?? minimum) : minimum
            guard time - anchor >= need else { continue }
            cuts.append(time)
            anchor = time
        }
        // A last piece shorter than a second is folded into the one before it.
        if cuts.count > 1, duration - (cuts.last ?? 0) < 1 { cuts.removeLast() }
        var result: [RemuxSegmentSpan] = []
        for (index, start) in cuts.enumerated() {
            let end = index + 1 < cuts.count ? cuts[index + 1] : duration
            result.append(RemuxSegmentSpan(index: index, start: start, end: end))
        }
        return result
    }
}
