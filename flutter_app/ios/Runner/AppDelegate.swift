import AVFoundation
import AVKit
import MediaPlayer
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nowPlaying: NowPlayingBridge?
  private var downloads: BackgroundDownloadBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Playback category: the sound keeps going to AirPlay speakers and with the screen locked.
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    // New-episode notifications also show while the app is open.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    BackgroundDownloadBridge.shared.systemCompletion = completionHandler
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AetherAirPlay") {
      registrar.register(AirPlayPickerFactory(), withId: "aether/airplay")
      AirPlayPresenter.shared.attach(messenger: registrar.messenger())
      nowPlaying = NowPlayingBridge(messenger: registrar.messenger())
      downloads = BackgroundDownloadBridge.shared
      downloads?.attach(messenger: registrar.messenger())
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

/// Lock screen / Control Center: «Now Playing» information and the remote commands, carried to and from Dart.
final class NowPlayingBridge {
  private let channel: FlutterMethodChannel
  private var artworkURL: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "aether/nowplaying", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "update":
        self?.update(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "clear":
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        self?.artworkURL = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in self?.send("play"); return .success }
    center.pauseCommand.addTarget { [weak self] _ in self?.send("pause"); return .success }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send("toggle"); return .success }
    center.skipForwardCommand.preferredIntervals = [10]
    center.skipForwardCommand.addTarget { [weak self] _ in self?.send("forward"); return .success }
    center.skipBackwardCommand.preferredIntervals = [10]
    center.skipBackwardCommand.addTarget { [weak self] _ in self?.send("back"); return .success }
    center.nextTrackCommand.addTarget { [weak self] _ in self?.send("next"); return .success }
    center.previousTrackCommand.addTarget { [weak self] _ in self?.send("previous"); return .success }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      if let e = event as? MPChangePlaybackPositionCommandEvent { self?.send("seek", ["position": e.positionTime]) }
      return .success
    }
  }

  private func send(_ name: String, _ extra: [String: Any] = [:]) {
    var args = extra
    args["name"] = name
    DispatchQueue.main.async { self.channel.invokeMethod("command", arguments: args) }
  }

  private func update(_ a: [String: Any]) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: a["title"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: a["duration"] as? Double ?? 0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: a["position"] as? Double ?? 0,
      MPNowPlayingInfoPropertyPlaybackRate: (a["playing"] as? Bool ?? false) ? (a["rate"] as? Double ?? 1) : 0,
    ]
    if let sub = a["subtitle"] as? String { info[MPMediaItemPropertyArtist] = sub }
    if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] { info[MPMediaItemPropertyArtwork] = existing }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    let center = MPRemoteCommandCenter.shared()
    center.nextTrackCommand.isEnabled = a["hasNext"] as? Bool ?? false
    center.previousTrackCommand.isEnabled = a["hasPrevious"] as? Bool ?? false
    if let url = a["artwork"] as? String, url != artworkURL, let u = URL(string: url) {
      artworkURL = url
      URLSession.shared.dataTask(with: u) { data, _, _ in
        guard let data, let image = UIImage(data: data) else { return }
        let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        DispatchQueue.main.async {
          var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
          current[MPMediaItemPropertyArtwork] = art
          MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
      }.resume()
    }
  }
}


/// Downloads that go on with the app closed: a background URLSession, which the system keeps running (and wakes the app for when
/// a file is done). Dart asks for a transfer by id; results that arrive while Dart is not listening wait in UserDefaults.
final class BackgroundDownloadBridge: NSObject, URLSessionDownloadDelegate {
  static let shared = BackgroundDownloadBridge()
  var systemCompletion: (() -> Void)?
  private var channel: FlutterMethodChannel?
  private let store = UserDefaults.standard
  private let pendingKey = "aether.bgdownload.finished"
  private let destKey = "aether.bgdownload.dest"
  private let titleKey = "aether.bgdownload.title"

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: "app.aether.background-downloads")
    config.sessionSendsLaunchEvents = true
    config.isDiscretionary = false
    config.allowsCellularAccess = true
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "aether/bgdownload", binaryMessenger: messenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      switch call.method {
      case "start":
        self.start(id: id, args: args)
        result(true)
      case "cancel":
        self.session.getAllTasks { tasks in
          tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() }
        }
        result(true)
      case "pending":
        result(self.store.dictionary(forKey: self.pendingKey) ?? [:])
      case "ack":
        var d = self.store.dictionary(forKey: self.pendingKey) ?? [:]
        d.removeValue(forKey: id)
        self.store.set(d, forKey: self.pendingKey)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(id: String, args: [String: Any]) {
    guard let urlString = args["url"] as? String, let url = URL(string: urlString),
          let dest = args["dest"] as? String else { return }
    session.getAllTasks { [weak self] tasks in
      guard let self = self else { return }
      // Still running from before the app was closed: just listen to it again.
      if tasks.contains(where: { $0.taskDescription == id }) { return }
      var req = URLRequest(url: url)
      for (k, v) in (args["headers"] as? [String: String] ?? [:]) { req.setValue(v, forHTTPHeaderField: k) }
      let task = self.session.downloadTask(with: req)
      task.taskDescription = id
      var dests = self.store.dictionary(forKey: self.destKey) as? [String: String] ?? [:]
      dests[id] = dest
      self.store.set(dests, forKey: self.destKey)
      var titles = self.store.dictionary(forKey: self.titleKey) as? [String: String] ?? [:]
      if args["notify"] as? Bool ?? false {
        titles[id] = args["title"] as? String ?? "Download"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
      } else {
        titles.removeValue(forKey: id)
      }
      self.store.set(titles, forKey: self.titleKey)
      task.resume()
    }
  }

  /// «Download completato», also when the app is closed (the system wakes it for a moment when a file is done).
  private func announce(_ id: String, ok: Bool) {
    var titles = store.dictionary(forKey: titleKey) as? [String: String] ?? [:]
    guard let title = titles.removeValue(forKey: id) else { return }
    store.set(titles, forKey: titleKey)
    let content = UNMutableNotificationContent()
    content.title = ok ? "Download completato" : "Download non riuscito"
    content.body = title
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dl-\(id)", content: content, trigger: nil))
  }

  private func record(_ id: String, _ info: [String: Any]) {
    announce(id, ok: info["ok"] as? Bool ?? false)
    var d = store.dictionary(forKey: pendingKey) ?? [:]
    d[id] = info
    store.set(d, forKey: pendingKey)
    DispatchQueue.main.async { self.channel?.invokeMethod("finished", arguments: ["id": id, "info": info]) }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let id = downloadTask.taskDescription else { return }
    DispatchQueue.main.async {
      self.channel?.invokeMethod("progress", arguments: [
        "id": id, "received": totalBytesWritten, "total": max(totalBytesExpectedToWrite, 0),
      ])
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let id = downloadTask.taskDescription else { return }
    let http = downloadTask.response as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
    let textual = type.contains("text/") || type.contains("json") || type.contains("html")
    if status == 200 && !textual, let dests = store.dictionary(forKey: destKey) as? [String: String], let dest = dests[id] {
      let target = URL(fileURLWithPath: dest)
      try? FileManager.default.removeItem(at: target)
      do {
        try FileManager.default.moveItem(at: location, to: target)
        record(id, ["ok": true, "status": status, "size": size])
        return
      } catch {
        record(id, ["ok": false, "status": 0, "snippet": "Impossibile salvare il file."])
        return
      }
    }
    // An error page or a message instead of the video: hand a bit of it to Dart, so the reason can be shown.
    var snippet = ""
    if let h = try? FileHandle(forReadingFrom: location) {
      snippet = String(data: h.readData(ofLength: 1024), encoding: .utf8) ?? ""
      try? h.close()
    }
    record(id, ["ok": false, "status": status == 200 ? 415 : status, "snippet": snippet])
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let id = task.taskDescription, let error = error else { return }
    let ns = error as NSError
    if ns.code == NSURLErrorCancelled { return }
    record(id, ["ok": false, "status": 0, "snippet": "", "network": true])
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async {
      self.systemCompletion?()
      self.systemCompletion = nil
    }
  }
}


/// Opens the system AirPlay list from a Flutter button: a hidden system picker is pressed in code (an AirPlay button drawn as a native
/// view inside the controls broke the drawing of the widgets painted after it).
final class AirPlayPresenter {
  static let shared = AirPlayPresenter()
  private var picker: AVRoutePickerView?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "aether/airplaypicker", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "show" else { return result(FlutterMethodNotImplemented) }
      self?.show()
      result(true)
    }
  }

  private func show() {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
    if picker == nil {
      let hidden = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
      hidden.alpha = 0.02
      hidden.prioritizesVideoDevices = true
      window.addSubview(hidden)
      picker = hidden
    }
    guard let picker = picker else { return }
    if picker.superview == nil { window.addSubview(picker) }
    for case let button as UIButton in picker.subviews { button.sendActions(for: .touchUpInside) }
  }
}
