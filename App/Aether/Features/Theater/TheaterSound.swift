import AVFoundation

/// The opening sound of Theater Mode, made from maths so no audio file is needed: a riser that climbs for about two and a half
/// seconds, then a low hit and a shimmer. It follows the silent switch.
@MainActor
enum TheaterSound {
    private static var player: AVAudioPlayer?

    static func playIntro() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        guard let player = try? AVAudioPlayer(data: wave()) else { return }
        player.volume = 0.8
        player.prepareToPlay()
        player.play()
        Self.player = player
    }

    static func stop() { player?.stop(); player = nil }

    private static func wave() -> Data {
        let rate = 44100.0
        let seconds = 8.0
        let hit = 3.4
        let count = Int(rate * seconds)
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        var seed: UInt32 = 12345
        func noise() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24) * 2 - 1
        }
        for i in 0..<count {
            let t = Double(i) / rate
            var v = 0.0
            if t < hit {
                let p = t / hit
                let frequency = 70 * pow(14, p)
                phase += 2 * Double.pi * frequency / rate
                let envelope = p * p
                v += (sin(phase) * 0.5 + sin(phase * 1.5) * 0.2) * envelope
                v += noise() * 0.18 * envelope * envelope
            } else {
                let tau = t - hit
                // A low, heavy gong: inharmonic partials around a deep fundamental, each with its own decay, the upper ones
                // blooming a little after the strike, two close tones beating under it and a dull thump at the start.
                let bloom = 1 - exp(-tau * 7)
                let partials: [(ratio: Double, level: Double, decay: Double)] = [
                    (1.0, 1.0, 0.42), (1.51, 0.7, 0.55), (2.0, 0.5, 0.8), (2.74, 0.36, 1.1), (3.7, 0.24, 1.6), (5.2, 0.12, 2.4),
                ]
                let base = 56.0
                for partial in partials {
                    let shape = partial.ratio < 1.2 ? 1 : bloom
                    v += sin(2 * Double.pi * base * partial.ratio * tau) * exp(-tau * partial.decay) * partial.level * shape * 0.55
                }
                v += sin(2 * Double.pi * (base + 1.7) * tau) * exp(-tau * 0.5) * 0.35
                v += sin(2 * Double.pi * (70 - 22 * min(1, tau / 0.4)) * tau) * exp(-tau * 6) * 0.8
                v += noise() * exp(-tau * 16) * 0.22
            }
            let fade = t > seconds - 1.0 ? max(0, seconds - t) : 1
            samples[i] = Int16(tanh(v * 0.45) * 0.9 * fade * Double(Int16.max))
        }
        var data = Data()
        func put32(_ x: UInt32) { var y = x.littleEndian; data.append(Data(bytes: &y, count: 4)) }
        func put16(_ x: UInt16) { var y = x.littleEndian; data.append(Data(bytes: &y, count: 2)) }
        let bytes = UInt32(count * 2)
        data.append("RIFF".data(using: .ascii)!); put32(36 + bytes); data.append("WAVEfmt ".data(using: .ascii)!)
        put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        data.append("data".data(using: .ascii)!); put32(bytes)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
