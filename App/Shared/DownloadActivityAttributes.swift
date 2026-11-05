import ActivityKit
import Foundation

/// The Live Activity of the downloads (Lock Screen and Dynamic Island).
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String?
        var fraction: Double
        var count: Int
        var finished: Bool
    }

    var name: String
}
