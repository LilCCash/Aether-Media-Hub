import SwiftUI
import UIKit
import AetherCore

/// Colours taken from the poster of a title (Settings ▸ Funzioni extra ▸ Colori dalla locandina). The maths is in AetherCore
/// (`PosterPaletteExtractor`, tested); this reads the pixels of a small copy of the picture.
enum PosterTint {
    @MainActor private static var cache: [String: PosterPalette] = [:]

    /// The palette of the picture at `address`, loaded through the app's image cache. nil when the picture cannot be read.
    @MainActor
    static func palette(for address: String?, loader: ImageLoader) async -> PosterPalette? {
        guard let address = address, let url = URL(string: address) else { return nil }
        if let known = cache[address] { return known }
        guard let image = await loader.image(for: url, maxPixel: 96), let pixels = pixels(of: image),
              let palette = PosterPaletteExtractor.palette(rgba: pixels) else { return nil }
        cache[address] = palette
        return palette
    }

    /// RGBA bytes of the picture scaled to 24 × 36.
    private static func pixels(of image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 24, height = 36
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    static func color(_ value: PosterColor) -> Color {
        return Color(red: value.red, green: value.green, blue: value.blue)
    }
}
