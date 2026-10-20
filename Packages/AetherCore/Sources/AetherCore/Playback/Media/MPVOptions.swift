import Foundation

/// Translates Aether's settings into libmpv option / property names and values. Pure so that it can be unit-tested
/// without libmpv; every name here is an option documented in mpv's manual (`options.rst`) except the
/// `gpu-context=moltenvk` context, which MPVKit adds with its `0001-player-add-moltenvk-context.patch`.
public enum MPVOptions {
    public struct Pair: Equatable, Sendable {
        public let name: String
        public let value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Options applied once, before `mpv_initialize`.
    /// - Parameter headlessVideo: use the `null` video output (used only by automated tests on machines without a GPU:
    ///   demuxing, decoding and timing still run, nothing is drawn).
    public static func initialOptions(video: VideoOutputSettings, device: DeviceVideoCapabilities,
                                      headlessVideo: Bool = false) -> [Pair] {
        var pairs: [Pair] = []
        // Behave as a library, not as the command-line player.
        pairs.append(Pair("config", "no"))
        pairs.append(Pair("terminal", "no"))
        pairs.append(Pair("osc", "no"))
        pairs.append(Pair("input-default-bindings", "no"))
        pairs.append(Pair("input-vo-keyboard", "no"))
        pairs.append(Pair("load-scripts", "no"))
        pairs.append(Pair("ytdl", "no"))
        pairs.append(Pair("idle", "yes"))
        pairs.append(Pair("keep-open", "yes"))
        pairs.append(Pair("force-window", "no"))
        pairs.append(Pair("sub-auto", "no"))
        pairs.append(Pair("audio-display", "no"))
        pairs.append(Pair("save-position-on-quit", "no"))
        pairs.append(Pair("user-agent", "Aether (iOS)"))
        pairs.append(Pair("network-timeout", "30"))
        // Audio: AudioUnit output; keep the clock running even when no audio device can be opened.
        pairs.append(Pair("ao", "audiounit"))
        pairs.append(Pair("audio-fallback-to-null", "yes"))
        // Video output.
        if headlessVideo {
            pairs.append(Pair("vo", "null"))
        } else {
            pairs.append(Pair("vo", "gpu-next"))
            pairs.append(Pair("gpu-api", "vulkan"))
            pairs.append(Pair("gpu-context", "moltenvk"))
            pairs.append(Pair("vulkan-swap-mode", "fifo"))
        }
        pairs.append(contentsOf: runtimeProperties(video: video, device: device))
        if video.bufferSeconds > 0 {
            pairs.append(Pair("cache", "yes"))
            pairs.append(Pair("cache-secs", "\(video.bufferSeconds)"))
            pairs.append(Pair("demuxer-readahead-secs", "\(video.bufferSeconds)"))
        }
        return pairs
    }

    /// Properties that may also be changed while a file is playing.
    public static func runtimeProperties(video: VideoOutputSettings, device: DeviceVideoCapabilities) -> [Pair] {
        var pairs: [Pair] = []
        pairs.append(Pair("hwdec", video.hardwareDecoding ? "videotoolbox" : "no"))
        // Let the display receive the HDR signal only when it can show it and the user did not ask for SDR.
        let passHDR = video.hdrMode == .auto && device.hasHDRDisplay
        pairs.append(Pair("target-colorspace-hint", passHDR ? "yes" : "no"))
        pairs.append(Pair("tone-mapping", video.toneMapping.mpvValue))
        pairs.append(Pair("hdr-compute-peak", video.computeHDRPeak ? "yes" : "no"))
        pairs.append(Pair("deband", video.deband ? "yes" : "no"))
        pairs.append(Pair("brightness", "\(video.brightness)"))
        pairs.append(Pair("contrast", "\(video.contrast)"))
        pairs.append(Pair("saturation", "\(video.saturation)"))
        pairs.append(Pair("gamma", "\(video.gamma)"))
        return pairs
    }

    /// Whether the layer that mpv draws into should be allowed to leave the SDR range.
    public static func wantsExtendedDynamicRange(video: VideoOutputSettings, device: DeviceVideoCapabilities) -> Bool {
        return video.hdrMode == .auto && device.hasHDRDisplay
    }

    /// One `http-header-fields-append` entry per header (a list option: appending avoids escaping commas in values).
    public static func headerOptions(_ headers: [String: String]) -> [Pair] {
        return headers.keys.sorted().compactMap { key -> Pair? in
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanKey.isEmpty, !cleanKey.contains(":"), !cleanKey.contains("\n"), !cleanKey.contains("\r") else { return nil }
            let value = (headers[key] ?? "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return Pair("http-header-fields-append", "\(cleanKey): \(value)")
        }
    }

    /// mpv's rendering of subtitles that mpv itself draws (embedded tracks), from Aether's subtitle style.
    /// External subtitles are drawn by the app and do not use these.
    public static func subtitleStyleProperties(_ style: SubtitleStyle) -> [Pair] {
        var pairs: [Pair] = []
        pairs.append(Pair("sub-scale", String(format: "%.2f", style.sizePercent / 100)))
        pairs.append(Pair("sub-bold", style.isBold ? "yes" : "no"))
        pairs.append(Pair("sub-color", normalisedColor(style.textColor, fallback: "#FFFFFF")))
        pairs.append(Pair("sub-border-size", style.outlineEnabled ? "3" : "0"))
        pairs.append(Pair("sub-border-color", normalisedColor(style.outlineColor, fallback: "#000000")))
        let alpha = Int((min(1, max(0, style.backgroundOpacity)) * 255).rounded())
        let background = normalisedColor(style.backgroundColor, fallback: "#000000").dropFirst()
        pairs.append(Pair("sub-back-color", "#" + String(format: "%02X", alpha) + background))
        pairs.append(Pair("sub-pos", "\(Int((100 - style.bottomOffsetPercent).rounded()))"))
        return pairs
    }

    static func normalisedColor(_ raw: String, fallback: String) -> String {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        let digits = Set("0123456789abcdefABCDEF")
        guard hex.count == 6, hex.allSatisfy({ digits.contains($0) }) else { return fallback }
        return "#" + hex.uppercased()
    }

    /// `panscan` value for "fit" (0) versus "fill the screen" (1).
    public static func panscan(fill: Bool) -> String { fill ? "1.0" : "0.0" }

    /// mpv wants a language code list for `alang` / `slang` ("it,ita,en,eng").
    public static func languagePriorityList(_ codes: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for code in codes {
            let lower = code.lowercased()
            guard !lower.isEmpty, lower != "off", lower != "system", !seen.contains(lower) else { continue }
            seen.insert(lower)
            result.append(lower)
        }
        return result.joined(separator: ",")
    }
}
