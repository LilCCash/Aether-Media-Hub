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
    public static func plan(keyframes: [Double], duration: Double, minimum: Double = 6) -> [RemuxSegmentSpan] {
        guard duration > 0 else { return [] }
        let sorted = Array(Set(keyframes.filter { $0 >= 0 && $0 < duration })).sorted()
        guard !sorted.isEmpty else { return [] }
        var cuts: [Double] = [0]
        for time in sorted where time - (cuts.last ?? 0) >= minimum {
            cuts.append(time)
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
