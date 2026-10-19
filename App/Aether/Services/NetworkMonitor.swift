import Foundation
import Network
import Combine

/// Observable reachability. `reconnectToken` changes whenever connectivity returns or the interface switches
/// (Wi-Fi ↔ cellular), so screens and the player can retry instead of staying on a stale failure.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var interfaceName = "—"
    @Published private(set) var reconnectToken = 0

    private let monitor = NWPathMonitor()
    private var lastInterface: String?
    private var lastOnline = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.apply(path) }
        }
        monitor.start(queue: DispatchQueue(label: "app.aether.network-monitor"))
    }

    deinit {
        monitor.cancel()
    }

    private func apply(_ path: NWPath) {
        let online = path.status == .satisfied
        let name: String
        if path.usesInterfaceType(.wifi) { name = "Wi-Fi" }
        else if path.usesInterfaceType(.cellular) { name = "Rete mobile" }
        else if path.usesInterfaceType(.wiredEthernet) { name = "Ethernet" }
        else { name = online ? "Altra" : "Nessuna" }

        let regained = online && !lastOnline
        let switched = online && lastInterface != nil && lastInterface != name
        isOnline = online
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        interfaceName = name
        if regained || switched { reconnectToken += 1 }
        lastOnline = online
        lastInterface = name
    }
}
