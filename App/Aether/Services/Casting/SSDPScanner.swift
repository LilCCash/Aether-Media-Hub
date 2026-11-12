import Foundation
import AetherCore
import Darwin

/// SSDP (UPnP discovery) over UDP multicast with plain BSD sockets.
///
/// Since iOS 14.5 sending to a multicast address requires Apple's `com.apple.developer.networking.multicast`
/// entitlement (granted on request, not by default). Without it `sendto` fails with EHOSTUNREACH / EPERM and the
/// scan reports that reason instead of silently finding nothing.
enum SSDPScanner {
    struct Outcome {
        var responses: [SSDP.Response]
        var failure: String?
    }

    /// Runs normal multicast discovery when the Apple entitlement is available, and also sends
    /// unicast M-SEARCH requests to manually entered local devices. Unicast does not require the
    /// multicast entitlement and lets users try a known renderer IP directly.
    static func scan(unicastHosts: [String] = [], includeMulticast: Bool = true,
                     duration: TimeInterval = 3) async -> Outcome {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanBlocking(unicastHosts: unicastHosts,
                                                             includeMulticast: includeMulticast,
                                                             duration: duration))
            }
        }
    }

    private static func scanBlocking(unicastHosts: [String], includeMulticast: Bool,
                                     duration: TimeInterval) -> Outcome {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            return Outcome(responses: [], failure: "Socket UDP non disponibile (\(String(cString: strerror(errno)))).")
        }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Different renderer stacks answer different standard UPnP search targets.
        // Query the root device, all services/devices, and the MediaRenderer explicitly.
        let packets = ["ssdp:all", "upnp:rootdevice", SSDP.mediaRendererTarget]
            .map { [UInt8](SSDP.searchRequest(target: $0)) }
        var multicastFailure: String?
        var multicastSent = false

        if includeMulticast {
            var ttl: UInt8 = 2
            setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = SSDP.port.bigEndian
            inet_pton(AF_INET, SSDP.multicastAddress, &destination.sin_addr)

            for packet in packets {
                let result = withUnsafePointer(to: &destination) { pointer -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if result < 0 {
                    multicastFailure = String(cString: strerror(errno))
                } else {
                    multicastSent = true
                }
                usleep(100_000)
            }
        }

        // A unicast M-SEARCH is a best-effort fallback for a user-supplied IP. It is ordinary UDP
        // unicast traffic, so it does not need com.apple.developer.networking.multicast.
        for entry in unicastHosts {
            guard let host = localIPv4Host(from: entry) else { continue }
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = SSDP.port.bigEndian
            guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { continue }

            for packet in packets {
                _ = withUnsafePointer(to: &destination) { pointer -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String: SSDP.Response] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let count = recvfrom(descriptor, &buffer, buffer.count, 0, nil, nil)
            if count <= 0 { continue }          // receive timeout: poll the deadline again
            if let response = SSDP.parse(Data(buffer[0..<count])) {
                found[response.location.absoluteString] = response
            }
        }
        let failure: String? = includeMulticast && !multicastSent
            ? "Invio multicast rifiutato dal sistema (\(multicastFailure ?? "errore sconosciuto")). Serve l'entitlement multicast di Apple."
            : nil
        return Outcome(responses: Array(found.values), failure: failure)
    }

    /// Accept only private/link-local IPv4 addresses from manual entries; never send discovery
    /// packets to public hosts. Entries may be an IP, IP:port, or a full HTTP(S) URL.
    private static func localIPv4Host(from entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let components = URLComponents(string: trimmed), let scheme = components.scheme,
           ["http", "https"].contains(scheme.lowercased()), let host = components.host {
            candidate = host
        } else if let colon = trimmed.lastIndex(of: ":"), !trimmed.contains("://") {
            candidate = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        } else {
            candidate = trimmed
        }
        guard let address = IPAddress.parse(candidate),
              case .v4 = address,
              address.addressClass == .privateNetwork || address.addressClass == .linkLocal else { return nil }
        return candidate
    }
}
