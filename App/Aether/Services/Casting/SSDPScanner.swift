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

    static func scan(duration: TimeInterval = 3) async -> Outcome {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanBlocking(duration: duration))
            }
        }
    }

    private static func scanBlocking(duration: TimeInterval) -> Outcome {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            return Outcome(responses: [], failure: "Socket UDP non disponibile (\(String(cString: strerror(errno)))).")
        }
        defer { close(descriptor) }

        var ttl: UInt8 = 2
        setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = SSDP.port.bigEndian
        inet_pton(AF_INET, SSDP.multicastAddress, &destination.sin_addr)

        let packet = [UInt8](SSDP.searchRequest())
        var sendFailure: String?
        var sentOnce = false
        for _ in 0..<2 {
            let result = withUnsafePointer(to: &destination) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result < 0 {
                sendFailure = String(cString: strerror(errno))
            } else {
                sentOnce = true
            }
            usleep(150_000)
        }
        if !sentOnce {
            let reason = sendFailure ?? "errore sconosciuto"
            return Outcome(responses: [], failure: "Invio multicast rifiutato dal sistema (\(reason)). Serve l'entitlement multicast di Apple: usa l'aggiunta manuale.")
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
        return Outcome(responses: Array(found.values), failure: nil)
    }
}
