import Foundation
import Testing
@testable import Kaset

/// Choosing the local address a Cast device should stream from.
@Suite(.tags(.service))
struct CastStreamAddressTests {
    // MARK: - IPv4 Parsing

    @Test("Parses dotted-quad addresses")
    func parsesIPv4() {
        #expect(CastStreamAddress.ipv4Value("0.0.0.0") == 0)
        #expect(CastStreamAddress.ipv4Value("192.168.1.5") == 0xC0A8_0105)
        #expect(CastStreamAddress.ipv4Value("255.255.255.255") == UInt32.max)
    }

    @Test("Rejects addresses that are not dotted quads")
    func rejectsMalformedIPv4() {
        #expect(CastStreamAddress.ipv4Value("192.168.1") == nil)
        #expect(CastStreamAddress.ipv4Value("192.168.1.256") == nil)
        #expect(CastStreamAddress.ipv4Value("not.an.address") == nil)
        #expect(CastStreamAddress.ipv4Value("") == nil)
    }

    // MARK: - Masks and Subnets

    @Test("Builds network masks from prefix lengths")
    func buildsNetworkMasks() {
        #expect(CastStreamAddress.networkMask(prefixLength: 0) == 0)
        #expect(CastStreamAddress.networkMask(prefixLength: 8) == 0xFF00_0000)
        #expect(CastStreamAddress.networkMask(prefixLength: 24) == 0xFFFF_FF00)
        #expect(CastStreamAddress.networkMask(prefixLength: 32) == UInt32.max)
    }

    @Test("Detects addresses sharing a subnet")
    func detectsSameSubnet() {
        #expect(CastStreamAddress.isSameSubnet("192.168.1.10", "192.168.1.20", prefixLength: 24))
        #expect(CastStreamAddress.isSameSubnet("10.0.0.1", "10.0.0.200", prefixLength: 16))
        #expect(!CastStreamAddress.isSameSubnet("192.168.2.10", "192.168.1.20", prefixLength: 24))
        #expect(!CastStreamAddress.isSameSubnet("bad", "192.168.1.20", prefixLength: 24))
    }

    @Test("Recognizes private address ranges")
    func recognizesPrivateAddresses() {
        #expect(CastStreamAddress.isPrivateAddress("10.5.5.5"))
        #expect(CastStreamAddress.isPrivateAddress("172.16.0.1"))
        #expect(CastStreamAddress.isPrivateAddress("192.168.0.12"))
        #expect(!CastStreamAddress.isPrivateAddress("172.32.0.1"))
        #expect(!CastStreamAddress.isPrivateAddress("8.8.8.8"))
    }

    // MARK: - Selection

    @Test("Prefers the interface on the device's subnet")
    func prefersDeviceSubnet() {
        let candidates = [
            CastStreamAddress.InterfaceAddress(name: "utun3", address: "10.8.0.2", prefixLength: 32),
            CastStreamAddress.InterfaceAddress(name: "en0", address: "192.168.1.10", prefixLength: 24),
        ]

        let address = CastStreamAddress.bestAddress(forDeviceHost: "192.168.1.55", candidates: candidates)
        #expect(address == "192.168.1.10")
    }

    @Test("Falls back to a wired-style private address when no subnet matches")
    func fallsBackToPrivateAddress() {
        let candidates = [
            CastStreamAddress.InterfaceAddress(name: "en5", address: "203.0.113.9", prefixLength: 24),
            CastStreamAddress.InterfaceAddress(name: "en1", address: "10.1.2.3", prefixLength: 24),
        ]

        let address = CastStreamAddress.bestAddress(forDeviceHost: "192.168.1.55", candidates: candidates)
        #expect(address == "10.1.2.3")
    }

    @Test("Ignores link-local addresses when anything else is available")
    func ignoresLinkLocalWhenPossible() {
        let candidates = [
            CastStreamAddress.InterfaceAddress(name: "en0", address: "169.254.10.20", prefixLength: 16),
            CastStreamAddress.InterfaceAddress(name: "en1", address: "192.168.4.7", prefixLength: 24),
        ]

        let address = CastStreamAddress.bestAddress(forDeviceHost: "192.168.4.99", candidates: candidates)
        #expect(address == "192.168.4.7")
    }

    @Test("Uses a link-local address when it is all there is")
    func usesLinkLocalAsLastResort() {
        let candidates = [
            CastStreamAddress.InterfaceAddress(name: "en0", address: "169.254.10.20", prefixLength: 16),
        ]

        let address = CastStreamAddress.bestAddress(forDeviceHost: "192.168.4.99", candidates: candidates)
        #expect(address == "169.254.10.20")
    }

    @Test("Uses a tunnel address only when nothing else exists")
    func usesTunnelAsLastResort() {
        let onlyTunnel = [CastStreamAddress.InterfaceAddress(name: "utun0", address: "100.64.0.2", prefixLength: 32)]
        #expect(CastStreamAddress.bestAddress(forDeviceHost: "192.168.1.5", candidates: onlyTunnel) == "100.64.0.2")

        let withEthernet = onlyTunnel + [
            CastStreamAddress.InterfaceAddress(name: "en0", address: "192.168.9.9", prefixLength: 24),
        ]
        #expect(CastStreamAddress.bestAddress(forDeviceHost: "192.168.9.40", candidates: withEthernet) == "192.168.9.9")
    }

    @Test("Handles a device named by its Bonjour instance rather than an address")
    func handlesBonjourInstanceName() {
        // Discovered devices carry their Bonjour instance name, which is what the fallback sees when
        // the control connection has not reported the interface it is using.
        let candidates = [
            CastStreamAddress.InterfaceAddress(name: "utun3", address: "10.8.0.2", prefixLength: 32),
            CastStreamAddress.InterfaceAddress(name: "en0", address: "192.168.1.10", prefixLength: 24),
        ]

        let address = CastStreamAddress.bestAddress(forDeviceHost: "Living Room TV", candidates: candidates)
        #expect(address == "192.168.1.10")
    }

    @Test("Returns nothing when the Mac has no IPv4 address")
    func returnsNilWithoutAddresses() {
        #expect(CastStreamAddress.bestAddress(forDeviceHost: "192.168.1.5", candidates: []) == nil)
    }

    @Test("Flags tunnel interfaces")
    func flagsTunnelInterfaces() {
        let tunnel = CastStreamAddress.InterfaceAddress(name: "utun2", address: "10.0.0.1", prefixLength: 32)
        let ethernet = CastStreamAddress.InterfaceAddress(name: "en0", address: "10.0.0.2", prefixLength: 24)

        #expect(tunnel.isTunnel)
        #expect(!ethernet.isTunnel)
        #expect(!ethernet.isLinkLocal)
    }
}
