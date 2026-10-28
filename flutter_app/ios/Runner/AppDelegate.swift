import AVFoundation
import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Playback category: the sound keeps going to AirPlay speakers and with the screen locked.
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AetherAirPlay") {
      registrar.register(AirPlayPickerFactory(), withId: "aether/airplay")
    }
  }
}

/// The system AirPlay button (the same one the iOS app shows), as a Flutter platform view.
final class AirPlayPickerFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return AirPlayPickerView(frame: frame)
  }
}

final class AirPlayPickerView: NSObject, FlutterPlatformView {
  private let picker = AVRoutePickerView()

  init(frame: CGRect) {
    picker.frame = frame
    picker.tintColor = .white
    picker.activeTintColor = UIColor(red: 0.49, green: 0.55, blue: 1.0, alpha: 1)
    picker.prioritizesVideoDevices = true
    super.init()
  }

  func view() -> UIView { picker }
}
