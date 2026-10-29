import AVFoundation
import Flutter
import Foundation
import AetherCore

/// Channel `aether/remux`: `available`, `open {url, headers, languages, audioIndex, lan}` → `{id, url, lan, audio: [...]}`, `close`.
public class AetherNativePlugin: NSObject, FlutterPlugin {
    @MainActor private static let host = RemuxHost()
    private static var channel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "aether/remux", binaryMessenger: registrar.messenger())
        AetherNativePlugin.channel = channel
        Task { @MainActor in
            AetherNativePlugin.host.log = { text in AetherNativePlugin.channel?.invokeMethod("log", arguments: ["m": text]) }
        }
        registrar.addMethodCallDelegate(AetherNativePlugin(), channel: channel)
        // Tells Dart when the sound/picture goes to or comes back from an AirPlay receiver: the converted file must then be served on the
        // Wi-Fi address (the receiver cannot reach 127.0.0.1).
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            channel.invokeMethod("route", arguments: ["airplay": airPlayActive()])
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "available":
            result(FFmpegAvailability.isLinked)
        case "airplay":
            result(airPlayActive())
        case "close":
            Task { @MainActor in
                AetherNativePlugin.host.close()
                result(true)
            }
        case "forward":
            guard let text = args["url"] as? String, let url = URL(string: text) else {
                result(FlutterError(code: "remux", message: "Indirizzo non valido.", details: nil))
                return
            }
            let headers = args["headers"] as? [String: String] ?? [:]
            let ext = args["ext"] as? String ?? "mp4"
            Task { @MainActor in
                do {
                    let opened = try await AetherNativePlugin.host.forward(RelayUpstream(url: url, headers: headers), ext: ext)
                    result(["id": opened.id, "url": opened.url.absoluteString, "lan": true, "audio": []])
                } catch {
                    result(FlutterError(code: "remux", message: AetherNativePlugin.explain(error), details: nil))
                }
            }
        case "open":
            guard let text = args["url"] as? String, let url = URL(string: text) else {
                result(FlutterError(code: "remux", message: "Indirizzo non valido.", details: nil))
                return
            }
            let headers = args["headers"] as? [String: String] ?? [:]
            let languages = args["languages"] as? [String] ?? []
            let audio: RemuxAudioChoice = (args["audioIndex"] as? Int).map { .track(index: $0) } ?? .automatic(languages: languages)
            let lan = args["lan"] as? Bool ?? true
            Task { @MainActor in
                do {
                    let opened = try await AetherNativePlugin.host.open(RelayUpstream(url: url, headers: headers), audio: audio, preferLAN: lan)
                    let plan = opened.plan
                    let choices = (plan?.audioChoices.isEmpty ?? true) ? (plan?.audio ?? []) : (plan?.audioChoices ?? [])
                    result([
                        "id": opened.id,
                        "url": opened.url.absoluteString,
                        "lan": opened.lan,
                        "audio": choices.map { s in
                            ["index": s.index, "language": s.language ?? "", "title": s.title ?? "", "codec": s.codec, "isDefault": s.isDefault]
                        },
                    ])
                } catch {
                    result(FlutterError(code: "remux", message: AetherNativePlugin.explain(error), details: nil))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func explain(_ error: Error) -> String {
        if let remux = error as? RemuxError { return remux.message }
        if let local = error as? RemuxHostError {
            switch local {
            case .unavailable: return "La conversione dei file MKV non è disponibile in questa versione."
            case .notOnTheNetwork: return "I file scaricati non si possono convertire al volo."
            case .blocked: return "L'indirizzo della sorgente non è consentito."
            case .noLAN: return "Serve il Wi-Fi: il telefono e la TV devono stare sulla stessa rete."
            }
        }
        switch RelayError.mapping(error) {
        case .upstreamNoRanges:
            return "Questa sorgente non permette di leggere il video a pezzi, quindi non si può convertire al volo."
        case .upstreamUnreachable:
            return "Non riesco a raggiungere la sorgente."
        case .upstreamRejected(let status):
            return "La sorgente ha risposto con un errore (\(status))."
        default:
            return "La sorgente ha risposto in modo inatteso e non si può convertire."
        }
    }
}

func airPlayActive() -> Bool {
    return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
}
