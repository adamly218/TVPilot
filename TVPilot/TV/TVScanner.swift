import Foundation
import Observation

/// Finds Samsung TVs by asking every address on the phone's /24 subnet for the TV's
/// info endpoint. (Plain unicast HTTP, so it needs no multicast entitlement.)
@MainActor
@Observable
final class TVScanner {
    private(set) var found: [SavedTV] = []
    private(set) var isScanning = false
    private(set) var message: String?

    func scan() async {
        guard !isScanning else { return }
        guard let ip = LocalNetwork.wifiIPv4() else {
            message = "Connect your phone to Wi-Fi to find your TV."
            return
        }
        isScanning = true
        message = nil
        found = []
        defer { isScanning = false }

        let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
        let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != ip }

        await withTaskGroup(of: SavedTV?.self) { group in
            var next = 0
            func addNext() {
                guard next < hosts.count else { return }
                let host = hosts[next]
                next += 1
                group.addTask { await Self.probe(host) }
            }
            for _ in 0..<48 { addNext() }
            for await tv in group {
                if let tv, !found.contains(where: { $0.host == tv.host }) {
                    found.append(tv)
                }
                addNext()
            }
        }
        if found.isEmpty {
            message = "No TVs found. Check the TV is on and on the same Wi-Fi, or add it by IP address."
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Asks one address whether it's a Samsung TV.
    nonisolated static func probe(_ host: String) async -> SavedTV? {
        guard let url = URL(string: "http://\(host):8001/api/v2/"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any] else { return nil }
        let name = (device["name"] as? String) ?? (json["name"] as? String) ?? "Samsung TV"
        return SavedTV(
            name: name.replacingOccurrences(of: "[TV] ", with: ""),
            host: host,
            model: device["modelName"] as? String,
            mac: device["wifiMac"] as? String)
    }
}

enum LocalNetwork {
    /// The phone's IPv4 address on Wi-Fi (en0).
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

enum WakeOnLAN {
    /// Sends a magic packet so a TV in network standby turns on.
    static func wake(mac: String, host: String) {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count == 12 else { return }
        var macBytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return }
            macBytes.append(byte)
            index = end
        }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += macBytes }

        var targets = ["255.255.255.255", host]
        let parts = host.split(separator: ".")
        if parts.count == 4 { targets.append(parts.prefix(3).joined(separator: ".") + ".255") }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        for target in targets {
            for port: UInt16 in [9, 7] {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
                _ = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }
}
