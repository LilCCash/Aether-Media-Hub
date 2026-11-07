import Foundation

/// What Aether has learnt about how reliable each addon's sources were when they were played: the ones that start earn a few points in the
/// ranking, the ones that fail lose some. Counts fade slowly, so a service that was down last month is not punished for ever.
public struct SourceReliability: Codable, Equatable, Sendable {
    public struct Tally: Codable, Equatable, Sendable {
        public var ok: Double = 0
        public var bad: Double = 0
        public init(ok: Double = 0, bad: Double = 0) { self.ok = ok; self.bad = bad }
    }

    public var tallies: [String: Tally] = [:]
    public init() {}

    private static let fade = 0.97
    private static let keep = 40

    /// Notes how a source of this addon went: it started (`true`) or it failed (`false`).
    public mutating func record(addonID: String, success: Bool) {
        guard !addonID.isEmpty else { return }
        var tally = tallies[addonID] ?? Tally()
        tally.ok *= SourceReliability.fade
        tally.bad *= SourceReliability.fade
        if success { tally.ok += 1 } else { tally.bad += 1 }
        tallies[addonID] = tally
        if tallies.count > SourceReliability.keep {
            // Forget the addons with the fewest plays.
            let weakest = tallies.sorted { $0.value.ok + $0.value.bad < $1.value.ok + $1.value.bad }.prefix(tallies.count - SourceReliability.keep)
            for entry in weakest { tallies[entry.key] = nil }
        }
    }

    /// Points for a source of this addon: from -60 (it keeps failing) to +30 (it always starts). Zero until there are at least three plays.
    public func bonus(addonID: String?) -> Int {
        guard let id = addonID, let tally = tallies[id] else { return 0 }
        let total = tally.ok + tally.bad
        guard total >= 3 else { return 0 }
        let ratio = (tally.ok + 1) / (total + 2)
        return max(-60, min(30, Int(((ratio - 0.7) * 100).rounded())))
    }

    public var isEmpty: Bool { return tallies.isEmpty }
}
