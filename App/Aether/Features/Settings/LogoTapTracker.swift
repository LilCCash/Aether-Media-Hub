import Foundation
import CoreGraphics

/// Counts the taps on the logo in About: the kernel heats up with every tap, the seventh makes it pop, and if the viewer stops
/// for a moment it cools down again. Pure logic, the clock is passed in (monotonic seconds, `systemUptime`), so it is tested
/// without a screen.
struct LogoTapTracker {
    enum Outcome: Equatable {
        /// A tap during the rest after a pop; hammering cannot trigger a second pop right away.
        case ignored
        /// 1...(popThreshold - 1) taps in a row.
        case heat(level: Int)
        /// The `popCount`-th pop of this visit (1-based).
        case pop(popCount: Int)
    }

    static let popThreshold = 7
    /// A longer pause than this and the count starts over.
    static let resetWindow: TimeInterval = 1.5
    /// The window when VoiceOver is on: a double-tap per press is slow.
    static let voiceOverWindow: TimeInterval = 5
    /// Rest after a pop.
    static let cooldown: TimeInterval = 3.6

    private(set) var taps = 0
    private(set) var popCount = 0
    private var lastTap: TimeInterval?
    private var restUntil: TimeInterval?

    init() {}

    mutating func register(at now: TimeInterval, window: TimeInterval = LogoTapTracker.resetWindow) -> Outcome {
        if let until = restUntil {
            // A clock that went backwards must not freeze the logo.
            if now < until, now >= (lastTap ?? now) { return .ignored }
            restUntil = nil
            taps = 0
        }
        if let last = lastTap, now < last || now - last >= window { taps = 0 }
        taps += 1
        lastTap = now
        if taps >= LogoTapTracker.popThreshold {
            taps = 0
            popCount += 1
            restUntil = now + LogoTapTracker.cooldown
            return .pop(popCount: popCount)
        }
        return .heat(level: taps)
    }

    /// The heat falls back to nothing (the viewer stopped tapping).
    mutating func cooldownElapsed() {
        taps = 0
    }
}

/// How hard each stage of the heat taps back, 0...1. Monotonic: the kernel gets hotter.
enum LogoHaptics {
    static func intensity(forHeat level: Int) -> Double {
        let table: [Double] = [0.25, 0.30, 0.40, 0.50, 0.65, 0.80]
        let index = min(max(level, 1), table.count) - 1
        return table[index]
    }
}

/// What the logo says.
enum LogoEasterEggText {
    static func heat(level: Int) -> String? {
        switch level {
        case 3: return "Ehi, che solletico!"
        case 5: return "Si scalda… ancora un po'."
        default: return nil
        }
    }

    static let unlockLine = "Tema Popcorn sbloccato: lo trovi in Impostazioni ▸ Aspetto ▸ Stile e grafica."

    static let pops = [
        "POP! Il popcorn è pronto.",
        "Aether non raccoglie dati, solo popcorn.",
        "Nessun film è stato maltrattato in questo easter egg.",
        "Ora con più burro.",
        "Spegni il telefono e guardati un film.",
        "Il prossimo che tocca il logo offre i popcorn."
    ]

    /// The text of the `count`-th pop (1-based). The first pop that unlocks the secret adds the line that says where it went.
    static func pop(count: Int, unlockedNow: Bool) -> String {
        let index = (max(count, 1) - 1) % pops.count
        let base = pops[index]
        return unlockedNow ? base + "\n" + unlockLine : base
    }
}

/// The burst of popcorn: where each piece goes, as a closed-form function of time (no per-frame state, so it is exact and
/// testable). Pieces leave the logo, climb, and fall off the bottom of the screen.
struct PopcornShower {
    struct Piece: Equatable {
        /// Seconds after the pop at which the piece leaves.
        var delay: Double
        /// Launch velocity in points per second (negative `vy` is up).
        var vx: Double
        var vy: Double
        /// Rotation in radians per second.
        var spin: Double
        /// 0.7...1.3, a scale for the glyph.
        var scale: Double
        /// Index into the glyph list.
        var glyph: Int
    }

    static let duration: TimeInterval = 3.2
    static let gravity: Double = 1400
    static let glyphs = ["🍿", "🎞️", "🎬"]
    static let baseGlyphSize: Double = 28

    let pieces: [Piece]

    init(seed: UInt64, count: Int) {
        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func next() -> Double {
            // SplitMix64: deterministic for a seed.
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z % 1_000_000) / 1_000_000
        }
        let clamped = min(max(count, 0), 60)
        var made: [Piece] = []
        for _ in 0..<clamped {
            made.append(Piece(delay: next() * 0.4,
                              vx: (next() - 0.5) * 440,
                              vy: -(350 + next() * 550),
                              spin: (next() - 0.5) * 14,
                              scale: 0.7 + next() * 0.6,
                              glyph: Int(next() * Double(PopcornShower.glyphs.count)) % PopcornShower.glyphs.count))
        }
        pieces = made
    }

    /// The piece's position `t` seconds after the pop, or nil before it leaves and after it has left the screen.
    func position(of piece: Piece, at t: TimeInterval, origin: CGPoint, in size: CGSize) -> CGPoint? {
        let dt = t - piece.delay
        guard dt >= 0, t <= PopcornShower.duration else { return nil }
        let x = origin.x + piece.vx * dt
        let y = origin.y + piece.vy * dt + 0.5 * PopcornShower.gravity * dt * dt
        let margin = PopcornShower.baseGlyphSize * piece.scale
        if y > size.height + margin { return nil }
        // Kernels bounce off the side edges instead of leaving, so the rain stays on screen.
        let clampedX = min(max(x, 0), size.width)
        return CGPoint(x: clampedX, y: y)
    }
}
