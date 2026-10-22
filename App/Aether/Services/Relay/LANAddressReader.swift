import Foundation
import Darwin
import AetherCore

/// Reads the phone's network interfaces from the system. The choice of which one the relay listens on is `LANInterfaceSelector`'s.
enum LANAddressReader {
    static func current() -> LANInterface? {
        return LANInterfaceSelector.pick(from: interfaces())
    }

    static func interfaces() -> [RawInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [RawInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let entry = node.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask,
                  let ip = text(of: address), let netmask = text(of: mask) else { continue }
            let flags = Int32(entry.ifa_flags)
            result.append(RawInterface(name: String(cString: entry.ifa_name), address: ip, netmask: netmask,
                                       isUp: flags & IFF_UP != 0, isRunning: flags & IFF_RUNNING != 0,
                                       isLoopback: flags & IFF_LOOPBACK != 0))
        }
        return result
    }

    private static func text(of address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return status == 0 ? String(cString: buffer) : nil
    }
}
