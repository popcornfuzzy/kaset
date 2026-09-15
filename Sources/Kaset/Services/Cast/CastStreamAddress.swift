import Foundation

// MARK: - CastStreamAddress

/// Chooses the local address a Cast device should use to reach Kaset's audio stream.
///
/// A Mac usually has several addresses (Wi-Fi, Ethernet, VPN tunnels). The Cast device has to be
/// able to dial the one we advertise, so Kaset prefers a local address on the same subnet as the
/// device and only falls back to a general-purpose address when nothing matches.
enum CastStreamAddress {
    /// A local interface address.
    struct InterfaceAddress: Equatable, Sendable {
        /// BSD interface name, e.g. `en0`.
        let name: String

        /// Dotted-quad IPv4 address.
        let address: String

        /// Prefix length derived from the interface netmask.
        let prefixLength: Int

        /// Whether the interface is a tunnel (VPN), which Cast devices cannot usually reach.
        var isTunnel: Bool {
            self.name.hasPrefix("utun") || self.name.hasPrefix("ipsec") || self.name.hasPrefix("tun")
        }

        /// Whether the address is link-local (`169.254.0.0/16`).
        var isLinkLocal: Bool {
            self.address.hasPrefix("169.254.")
        }
    }

    /// Parses a dotted-quad IPv4 address into its 32-bit value.
    static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    /// The network mask for a prefix length.
    static func networkMask(prefixLength: Int) -> UInt32 {
        guard prefixLength > 0 else { return 0 }
        guard prefixLength < 32 else { return .max }
        return ~UInt32(0) << (32 - prefixLength)
    }

    /// Whether two addresses share a subnet under the given prefix length.
    static func isSameSubnet(_ lhs: String, _ rhs: String, prefixLength: Int) -> Bool {
        guard
            let lhsValue = self.ipv4Value(lhs),
            let rhsValue = self.ipv4Value(rhs)
        else { return false }

        let mask = self.networkMask(prefixLength: prefixLength)
        return lhsValue & mask == rhsValue & mask
    }

    /// Picks the best local address for reaching `deviceHost`.
    ///
    /// Preference order: an address on the device's own subnet, then any non-tunnel address, then
    /// anything at all. Link-local and tunnel addresses are only used when nothing else exists.
    static func bestAddress(forDeviceHost deviceHost: String, candidates: [InterfaceAddress]) -> String? {
        let usable = candidates.filter { !$0.isLinkLocal }
        let pool = usable.isEmpty ? candidates : usable

        if !pool.isEmpty {
            let sameSubnet = pool.filter { candidate in
                self.isSameSubnet(candidate.address, deviceHost, prefixLength: candidate.prefixLength)
                    || self.isSameSubnet(candidate.address, deviceHost, prefixLength: 24)
            }
            if let match = sameSubnet.first(where: { !$0.isTunnel }) ?? sameSubnet.first {
                return match.address
            }
        }

        if let preferred = pool.first(where: { !$0.isTunnel && self.isPrivateAddress($0.address) }) {
            return preferred.address
        }

        return pool.first?.address ?? candidates.first?.address
    }

    /// Whether an address is in a private range, which is what Cast devices live on.
    static func isPrivateAddress(_ address: String) -> Bool {
        guard let value = self.ipv4Value(address) else { return false }

        let tenNet = self.ipv4Value("10.0.0.0")!
        let oneSeventyTwoNet = self.ipv4Value("172.16.0.0")!
        let oneNinetyTwoNet = self.ipv4Value("192.168.0.0")!

        return value & self.networkMask(prefixLength: 8) == tenNet
            || value & self.networkMask(prefixLength: 12) == oneSeventyTwoNet
            || value & self.networkMask(prefixLength: 16) == oneNinetyTwoNet
    }

    /// Reads every IPv4 address currently assigned to this Mac.
    static func localIPv4Addresses() -> [InterfaceAddress] {
        var addresses: [InterfaceAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }

            guard
                let socketAddress = interface.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name != "lo0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: host)
            guard self.ipv4Value(address) != nil else { continue }

            addresses.append(
                InterfaceAddress(
                    name: name,
                    address: address,
                    prefixLength: self.prefixLength(netmask: interface.pointee.ifa_netmask)
                )
            )
        }

        return addresses
    }

    /// Derives a prefix length from an interface netmask.
    private static func prefixLength(netmask: UnsafeMutablePointer<sockaddr>?) -> Int {
        guard let netmask, netmask.pointee.sa_family == UInt8(AF_INET) else { return 24 }

        let mask = withUnsafePointer(to: &netmask.pointee) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        let value = UInt32(bigEndian: mask.s_addr)

        return value.nonzeroBitCount
    }
}
