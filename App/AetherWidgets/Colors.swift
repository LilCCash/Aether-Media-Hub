import SwiftUI

extension Color {
    /// «RRGGBB» as written into the snapshot by the app.
    init?(hex: String?) {
        guard let hex = hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

/// A steady colour for a name (a quote's film), so the same film always has the same look.
func hueColors(_ text: String) -> [Color] {
    let sum = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
    let hue = Double(sum) / 360
    return [Color(hue: hue, saturation: 0.55, brightness: 0.45), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.2)]
}
