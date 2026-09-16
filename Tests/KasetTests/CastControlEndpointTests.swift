import Foundation
import Network
import Testing
@testable import Kaset

/// Endpoint selection for the Cast control connection.
///
/// A device found over Bonjour has to be dialled through its service record. Its instance name is
/// not a hostname, so dialling it as one makes the connection wait on a name that can never resolve
/// until the attempt times out.
@Suite(.tags(.service))
struct CastControlEndpointTests {
    private static let serviceIdentity = CastServiceIdentity(
        name: "Chromecast-Ultra-1234",
        type: "_googlecast._tcp",
        domain: "local."
    )

    @Test("A browsed device is dialled through its Bonjour service")
    func usesServiceEndpointForBrowsedDevice() {
        let endpoint = CastControlEndpoint.endpoint(
            host: "Chromecast-Ultra-1234._googlecast._tcp.local.",
            port: 8009,
            service: Self.serviceIdentity
        )

        guard case let .service(name, type, domain, _) = endpoint else {
            Issue.record("Expected a Bonjour service endpoint, got \(endpoint)")
            return
        }

        #expect(name == "Chromecast-Ultra-1234")
        #expect(type == "_googlecast._tcp")
        #expect(domain == "local.")
    }

    @Test("A device without Bonjour coordinates is dialled by address")
    func usesHostPortWithoutServiceIdentity() {
        let endpoint = CastControlEndpoint.endpoint(host: "192.168.1.24", port: 8009, service: nil)

        guard case let .hostPort(host, port) = endpoint else {
            Issue.record("Expected a host-and-port endpoint, got \(endpoint)")
            return
        }

        #expect(host == NWEndpoint.Host("192.168.1.24"))
        #expect(port == NWEndpoint.Port(rawValue: 8009))
    }

    @Test("An unusable port falls back to the Cast control port")
    func fallsBackToDefaultPort() {
        let endpoint = CastControlEndpoint.endpoint(host: "192.168.1.24", port: 0, service: nil)

        guard case let .hostPort(_, port) = endpoint else {
            Issue.record("Expected a host-and-port endpoint, got \(endpoint)")
            return
        }

        #expect(port.rawValue == CastControlEndpoint.defaultPort)
    }

    @Test("An IPv4 address is read back from a local endpoint")
    func readsIPv4Address() throws {
        let address = try #require(IPv4Address("192.168.1.5"))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: 5555)

        #expect(CastControlEndpoint.ipv4Address(of: endpoint) == "192.168.1.5")
    }

    @Test("Endpoints that are not addresses have no local IPv4 address")
    func ignoresNonAddressEndpoints() {
        #expect(CastControlEndpoint.ipv4Address(of: NWEndpoint.hostPort(host: "example.com", port: 80)) == nil)
        #expect(CastControlEndpoint.ipv4Address(of: nil) == nil)
    }

    @Test("Discovery records the service identity on the device")
    func discoveryRecordsServiceIdentity() throws {
        let device = try #require(
            CastDiscoveryMetadata.device(
                from: ["fn": "Living Room TV", "id": "abc123"],
                host: "Chromecast-Ultra-1234._googlecast._tcp.local.",
                port: 8009,
                service: Self.serviceIdentity
            )
        )

        #expect(device.service == Self.serviceIdentity)
    }

    @Test("Devices built without Bonjour coordinates still work")
    func devicesWithoutServiceIdentity() throws {
        let device = try #require(
            CastDiscoveryMetadata.device(from: ["fn": "Kitchen"], host: "192.168.1.30", port: 8009)
        )

        #expect(device.service == nil)
        #expect(device.host == "192.168.1.30")
    }
}
