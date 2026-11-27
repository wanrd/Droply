import Foundation
import Security

public struct LocalNetworkInterface: Sendable, Equatable, Identifiable {
    public var id: String { "\(name):\(address)" }
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

public enum NetworkUtils {
    /// Generates a cryptographically secure 64-character hex pairing token (256-bit entropy).
    public static func generateSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns active IPv4 non-loopback interfaces, prioritizing Wi-Fi (`en0`).
    public static func activeIPv4Interfaces() -> [LocalNetworkInterface] {
        var interfaces: [LocalNetworkInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopback, let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(
                        decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                    let name = String(cString: interface.ifa_name)
                    let ignoredPrefixes = [
                        "utun", "tun", "tap", "ppp", "ipsec", "wg", "tailscale", "zt",
                        "awdl", "llw", "anpi", "gif", "stf", "lo", "vmnet", "vboxnet", "veth"
                    ]
                    let isIgnored = ignoredPrefixes.contains { name.hasPrefix($0) }
                    // Exclude link-local 169.254.x.x and VPN/virtual interfaces
                    if !isIgnored && !ip.hasPrefix("169.254.") {
                        interfaces.append(LocalNetworkInterface(name: name, address: ip))
                    }
                }
            }
            ptr = interface.ifa_next
        }

        return interfaces.sorted { lhs, rhs in
            if lhs.name == "en0" && rhs.name != "en0" { return true }
            if lhs.name != "en0" && rhs.name == "en0" { return false }
            if lhs.name.hasPrefix("en") && !rhs.name.hasPrefix("en") { return true }
            if !lhs.name.hasPrefix("en") && rhs.name.hasPrefix("en") { return false }
            return lhs.name < rhs.name
        }
    }

    public static func primaryWiFiIPv4() -> String {
        activeIPv4Interfaces().first?.address ?? "127.0.0.1"
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    public static func formatSpeed(bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 Б/с" }
        let clamped = UInt64(min(bytesPerSecond, Double(UInt64.max / 2)))
        return "\(formatBytes(clamped))/с"
    }
}
