import Foundation

/// One network interface as the system reports it, before any choice is made.
public struct RawInterface: Equatable, Sendable {
    public var name: String
    public var address: String
    public var netmask: String
    public var isUp: Bool
    public var isRunning: Bool
    public var isLoopback: Bool

    public init(name: String, address: String, netmask: String, isUp: Bool = true, isRunning: Bool = true, isLoopback: Bool = false) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLoopback = isLoopback
    }
}

/// The interface the relay listens on: the phone's Wi-Fi (or Personal Hotspot) IPv4 address.
public struct LANInterface: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case wifi, hotspot }

    public var name: String
    public var address: String
    public var netmask: String

    public init(name: String, address: String, netmask: String) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    public var kind: Kind { return name.hasPrefix("bridge") ? .hotspot : .wifi }

    /// Whether `peer` (a dotted-quad IPv4 address, nothing else) is in this interface's subnet.
    public func contains(peer: String) -> Bool {
        guard !peer.contains("%"), !peer.contains(":") else { return false }
        guard case .v4(let a, let b, let c, let d)? = IPAddress.parse(peer),
              case .v4(let la, let lb, let lc, let ld)? = IPAddress.parse(address),
              case .v4(let ma, let mb, let mc, let md)? = IPAddress.parse(netmask) else { return false }
        return (a & ma) == (la & ma) && (b & mb) == (lb & mb) && (c & mc) == (lc & mc) && (d & md) == (ld & md)
    }
}

public enum LANInterfaceSelector {
    private static let rejectedPrefixes = ["lo", "pdp_ip", "utun", "ipsec", "awdl", "llw", "ap"]

    /// Lower is better; nil means the interface is never used.
    private static func rank(of name: String) -> Int? {
        if rejectedPrefixes.contains(where: { name.hasPrefix($0) }) { return nil }
        if name == "en0" { return 0 }
        if name == "bridge100" { return 1 }
        if name.hasPrefix("en") { return 2 }
        return nil
    }

    /// The best private IPv4 interface that is up and running: Wi-Fi first, then the Personal Hotspot bridge, then other Ethernet-like
    /// interfaces. Loopback, cellular, VPN tunnels, AirDrop and similar are never chosen.
    public static func pick(from interfaces: [RawInterface]) -> LANInterface? {
        var best: (rank: Int, interface: LANInterface)?
        for raw in interfaces {
            guard raw.isUp, raw.isRunning, !raw.isLoopback, let rank = rank(of: raw.name) else { continue }
            guard case .v4? = IPAddress.parse(raw.address), IPAddress.parse(raw.address)?.addressClass == .privateNetwork else { continue }
            guard case .v4? = IPAddress.parse(raw.netmask) else { continue }
            let candidate = LANInterface(name: raw.name, address: raw.address, netmask: raw.netmask)
            if best == nil || rank < best!.rank { best = (rank, candidate) }
        }
        return best?.interface
    }
}
