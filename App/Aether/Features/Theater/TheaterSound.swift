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
        let seconds = 4.8
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
                v += sin(2 * Double.pi * 52 * tau) * exp(-tau * 2.6) * 0.95
                v += noise() * exp(-tau * 14) * 0.5
                v += sin(2 * Double.pi * 1760 * tau) * exp(-tau * 3.2) * 0.12
                v += sin(2 * Double.pi * 2349 * tau) * exp(-tau * 4.0) * 0.08
            }
            let fade = t > seconds - 0.15 ? max(0, (seconds - t) / 0.15) : 1
            samples[i] = Int16(max(-1, min(1, v * 0.8 * fade)) * Double(Int16.max))
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
