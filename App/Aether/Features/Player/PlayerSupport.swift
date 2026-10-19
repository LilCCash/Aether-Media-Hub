import SwiftUI
import MediaPlayer
import AVFoundation

/// Hosts the engine's video view.
struct PlayerSurface: UIViewRepresentable {
    let engine: PlaybackEngine

    func makeUIView(context: Context) -> UIView { engine.videoView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Screen brightness for the swipe gesture. Restored when the player closes.
@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var value: Double {
        get { Double(screen?.brightness ?? 0.5) }
        set { screen?.brightness = CGFloat(min(1, max(0, newValue))) }
    }
}

/// System output volume. iOS has no public setter; the established way is the slider inside an `MPVolumeView`,
/// which must live in the view hierarchy (kept off-screen).
@MainActor
final class SystemVolume: ObservableObject {
    fileprivate weak var view: MPVolumeView?

    var value: Double { Double(AVAudioSession.sharedInstance().outputVolume) }

    func set(_ newValue: Double) {
        let slider = view?.subviews.compactMap { $0 as? UISlider }.first
        slider?.value = Float(min(1, max(0, newValue)))
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    let controller: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        controller.view = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        controller.view = uiView
    }
}

/// Orientation lock owned by the app delegate; the player asks for landscape and gives it back when it closes.
@MainActor
enum OrientationController {
    static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

/// Seek bar with buffered range, drag-to-seek and VoiceOver increment / decrement.
struct PlayerScrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let accent: Color
    var onEditingChanged: (Bool) -> Void
    var onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let playedFraction = dragFraction ?? (duration > 0 ? clamp(position / duration) : 0)
            let bufferedFraction = duration > 0 ? clamp(buffered / duration) : 0
            let thumb: CGFloat = dragFraction == nil ? 14 : 22
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 5)
                Capsule().fill(Color.white.opacity(0.35)).frame(width: width * bufferedFraction, height: 5)
                Capsule().fill(accent).frame(width: width * playedFraction, height: 5)
                Circle().fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: width * playedFraction - thumb / 2)
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragFraction == nil { onEditingChanged(true) }
                        dragFraction = clamp(value.location.x / width)
                    }
                    .onEnded { value in
                        let fraction = clamp(value.location.x / width)
                        dragFraction = nil
                        onSeek(fraction * duration)
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Barra di avanzamento")
        .accessibilityValue("\(Format.duration(position)) di \(Format.duration(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, position + 10))
            case .decrement: onSeek(max(0, position - 10))
            @unknown default: break
            }
        }
    }
}

/// `gobackward.10`, `goforward.30`… exist only for these values.
func skipSymbol(seconds: Int, forward: Bool) -> String {
    let available: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
    let base = forward ? "goforward" : "gobackward"
    return available.contains(seconds) ? "\(base).\(seconds)" : base
}

enum PlayerSheet: String, Identifiable {
    case tracks, episodes, info, sources, cast
    var id: String { rawValue }
}
