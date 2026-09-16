import Foundation
import Testing
@testable import Kaset

/// Cast device discovery metadata and registry behaviour.
@Suite(.tags(.service))
struct CastDeviceTests {
    // MARK: - Discovery Metadata

    @Test("Builds a device from a full TXT record")
    func buildsDeviceFromFullRecord() throws {
        let device = try #require(
            CastDiscoveryMetadata.device(
                from: ["fn": "Living Room TV", "md": "Chromecast Ultra", "id": "abc123"],
                host: "192.168.1.24",
                port: 8009
            )
        )

        #expect(device.id == "abc123")
        #expect(device.name == "Living Room TV")
        #expect(device.model == "Chromecast Ultra")
        #expect(device.host == "192.168.1.24")
        #expect(device.port == 8009)
        #expect(device.displayAddress == "192.168.1.24:8009")
    }

    @Test("Falls back to the socket address when the record has no device id")
    func fallsBackToSocketAddressForID() throws {
        let device = try #require(
            CastDiscoveryMetadata.device(from: ["fn": "Kitchen"], host: "192.168.1.30", port: 8009)
        )

        #expect(device.id == "192.168.1.30:8009")
        #expect(device.model == nil)
    }

    @Test("A record without a friendly name is ignored")
    func ignoresRecordWithoutFriendlyName() {
        #expect(CastDiscoveryMetadata.device(from: [:], host: "192.168.1.30", port: 8009) == nil)
        #expect(CastDiscoveryMetadata.device(from: ["fn": "   "], host: "192.168.1.30", port: 8009) == nil)
    }

    @Test("Trims whitespace and drops an empty model")
    func trimsValuesAndDropsEmptyModel() throws {
        let device = try #require(
            CastDiscoveryMetadata.device(
                from: ["fn": "  Bedroom  ", "md": "  ", "id": "  xyz  "],
                host: "10.0.0.5",
                port: 8009
            )
        )

        #expect(device.name == "Bedroom")
        #expect(device.model == nil)
        #expect(device.id == "xyz")
    }

    @Test("The browsed service type is the Cast Bonjour service")
    func serviceTypeIsBonjourCast() {
        #expect(CastDiscoveryMetadata.serviceType == "_googlecast._tcp")
    }

    // MARK: - Registry

    @Test("Adding devices keeps them sorted by name")
    func registrySortsByName() {
        var registry = CastDeviceRegistry()
        registry.upsert(CastDevice(id: "b", name: "Bedroom", model: nil, host: "10.0.0.2", port: 8009))
        registry.upsert(CastDevice(id: "a", name: "Attic", model: nil, host: "10.0.0.3", port: 8009))
        registry.upsert(CastDevice(id: "l", name: "Living Room", model: nil, host: "10.0.0.4", port: 8009))

        #expect(registry.devices.map(\.name) == ["Attic", "Bedroom", "Living Room"])
    }

    @Test("Re-announcing a device updates it instead of duplicating it")
    func registryUpsertsByID() {
        var registry = CastDeviceRegistry()
        registry.upsert(CastDevice(id: "x", name: "Old Name", model: nil, host: "10.0.0.2", port: 8009))

        let changed = registry.upsert(CastDevice(id: "x", name: "New Name", model: nil, host: "10.0.0.9", port: 8009))

        #expect(changed)
        #expect(registry.devices.count == 1)
        #expect(registry.devices[0].name == "New Name")
        #expect(registry.devices[0].host == "10.0.0.9")
    }

    @Test("Re-announcing an unchanged device reports no change")
    func registryReportsNoChangeForIdenticalDevice() {
        var registry = CastDeviceRegistry()
        let device = CastDevice(id: "x", name: "Same", model: nil, host: "10.0.0.2", port: 8009)
        registry.upsert(device)

        let didChange = registry.upsert(device)
        #expect(didChange == false)
        #expect(registry.devices.count == 1)
    }

    @Test("Removing a device drops it from the list")
    func registryRemovesByID() {
        var registry = CastDeviceRegistry()
        registry.upsert(CastDevice(id: "x", name: "One", model: nil, host: "10.0.0.2", port: 8009))
        registry.upsert(CastDevice(id: "y", name: "Two", model: nil, host: "10.0.0.3", port: 8009))

        let removedFirst = registry.remove(id: "x")
        let removedMissing = registry.remove(id: "missing")
        #expect(removedFirst)
        #expect(removedMissing == false)
        #expect(registry.devices.map(\.id) == ["y"])

        registry.removeAll()
        #expect(registry.devices.isEmpty)
    }
}
