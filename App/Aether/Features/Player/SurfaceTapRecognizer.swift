import Foundation

/// Decides what a tap on the video means. The clock is passed in, so the rules can be unit-tested.
///
/// The first tap answers at once: when the controls are hidden they appear without waiting to see whether a second tap
/// follows. (That wait made people tap again, and the second tap then counted as a double tap that paused or skipped.)
/// Only hiding waits for the double-tap window, because a second tap may be on its way.
struct SurfaceTapRecognizer {
    /// A double tap needs a second tap within this time of the first.
    static let doubleTapWindow: TimeInterval = 0.28

    enum Outcome: Equatable {
        /// Controls hidden, or the player is locked: show the controls (or the unlock hint) now.
        case toggleNow
        /// Controls visible and a second tap may follow: hide them unless it does.
        case hideAfterWindow
        /// Controls visible and double taps are off: hide them now.
        case hideNow
        /// The second tap of a double tap. `restoreHidden`: the first tap had shown the controls, put them away again.
        case doubleTap(restoreHidden: Bool)
    }

    private var lastTapAt: Date?
    private var controlsVisibleBeforeTap = true

    mutating func register(at now: Date, canDoubleTap: Bool, isLocked: Bool, controlsVisible: Bool) -> Outcome {
        if canDoubleTap, let previous = lastTapAt, now.timeIntervalSince(previous) < Self.doubleTapWindow {
            lastTapAt = nil
            return .doubleTap(restoreHidden: !controlsVisibleBeforeTap && controlsVisible)
        }
        lastTapAt = canDoubleTap ? now : nil
        controlsVisibleBeforeTap = controlsVisible
        if isLocked || !controlsVisible { return .toggleNow }
        return canDoubleTap ? .hideAfterWindow : .hideNow
    }
}
