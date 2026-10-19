// Generates a small, valid H.264/MP4 file for the UI tests (macOS only; AVFoundation).
//
//   swiftc -O Tools/MakeFixtureVideo.swift -o makevideo && ./makevideo sample.mp4 150
//
// 320×180 at 5 fps, colour changing every second, "moov" atom first so it can be streamed over HTTP.
import AVFoundation
import CoreVideo
import Foundation

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "sample.mp4"
let seconds = arguments.count > 2 ? Int(arguments[2]) ?? 150 : 150
let width = 320
let height = 180
let fps = 5

let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: outputURL)

do {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 150_000,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "fixture", code: 1) }
    writer.startSession(atSourceTime: .zero)

    let total = seconds * fps
    for frame in 0..<total {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "fixture", code: 2) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixels = buffer else { throw NSError(domain: "fixture", code: 3) }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let second = frame / fps
            let blue = UInt8(40 + (second * 37) % 160)
            let green = UInt8(30 + (second * 53) % 120)
            let red = UInt8(60 + (second * 29) % 150)
            let bar = (frame % (fps * 4)) * width / (fps * 4)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let inBar = x >= bar && x < bar + 12
                    row[x * 4 + 0] = inBar ? 255 : blue
                    row[x * 4 + 1] = inBar ? 255 : green
                    row[x * 4 + 2] = inBar ? 255 : red
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "fixture", code: 4) }
    let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
    print("wrote \(outputPath): \(seconds) s, \(size ?? 0) bytes")
} catch {
    FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
    exit(1)
}
