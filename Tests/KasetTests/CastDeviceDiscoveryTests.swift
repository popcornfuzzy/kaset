import Foundation
import Testing
@testable import Kaset

/// Cast discovery publication behaviour.
///
/// The menu must show a device as soon as mDNS reports it. These tests cover the discovery side of
/// that promise: publishing is synchronous, uses the Bonjour identity rather than a resolved
/// address, and never blocks.
@Suite(.tags(.service))
@MainActor
struct CastDeviceDiscoveryTests {
    // MARK: - Publishing

    @Test("A device is published as soon as the browser reports it")
    func publishesImmediately() {
        let discovery = CastDeviceDiscovery()
        var publications: [[CastDevice]] = []
        discovery.onDevicesChanged = { publications.append($0) }

        discovery.apply(services: [Self.service(name: "Living Room TV", id: "abc123", model: "Chromecast Ultra")])

        // Nothing about publishing is asynchronous: if this ever needs an `await` or a delay to pass,
        // devices have gone back to appearing only after the browse window closes.
        #expect(publications.count == 1)
        #expect(discovery.devices.map(\.name) == ["Living Room TV"])
        #expect(discovery.devices.first?.model == "Chromecast Ultra")
    }

    @Test("Publishing does not resolve addresses")
    func publishingDoesNotResolveAddresses() throws {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [Self.service(name: "Kitchen", id: "k1")])

        let device = try #require(discovery.devices.first)

        // A Bonjour service instance is not a hostname: resolving it as one costs the full mDNS
        // timeout, so the instance name is kept and the connection dials the service endpoint.
        #expect(device.host == "Kitchen")
        #expect(device.service == Self.identity(for: "Kitchen"))
        #expect(device.displayAddress == "Kitchen:8009")
    }

    @Test("Publishing a batch of devices stays fast")
    func publishingIsNotBlocked() {
        let discovery = CastDeviceDiscovery()
        let services = (0 ..< 8).map { Self.service(name: "Device \($0)", id: "id\($0)") }

        let elapsed = ContinuousClock().measure {
            discovery.apply(services: services)
        }

        #expect(discovery.devices.count == 8)
        // Regression guard for the five-second stall: resolving each instance name would take the
        // full mDNS timeout, where this has to be effectively instant.
        #expect(elapsed < .seconds(1))
    }

    @Test("Devices are listed by name")
    func sortsByName() {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [
            Self.service(name: "Bedroom", id: "b"),
            Self.service(name: "Attic", id: "a"),
            Self.service(name: "Living Room", id: "l"),
        ])

        #expect(discovery.devices.map(\.name) == ["Attic", "Bedroom", "Living Room"])
    }

    // MARK: - Updates

    @Test("A re-announced device updates instead of duplicating")
    func reannounceUpdatesDevice() throws {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [Self.service(name: "Old Name", id: "x")])
        discovery.apply(services: [Self.service(name: "New Name", id: "x", model: "Chromecast")])

        #expect(discovery.devices.count == 1)

        let device = try #require(discovery.devices.first)
        #expect(device.name == "New Name")
        #expect(device.model == "Chromecast")
    }

    @Test("A device that is no longer advertised is removed")
    func removingDevicePrunesIt() {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [
            Self.service(name: "Living Room TV", id: "l"),
            Self.service(name: "Kitchen", id: "k"),
        ])

        var latest: [CastDevice] = []
        discovery.onDevicesChanged = { latest = $0 }

        discovery.apply(services: [Self.service(name: "Living Room TV", id: "l")])

        #expect(discovery.devices.map(\.name) == ["Living Room TV"])
        #expect(latest.map(\.name) == ["Living Room TV"])
    }

    @Test("A service without a friendly name is ignored")
    func ignoresNamelessService() {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [
            CastDiscoveredService(identity: Self.identity(for: "Nameless"), txtRecord: ["id": "n"]),
            Self.service(name: "Kitchen", id: "k"),
        ])

        #expect(discovery.devices.map(\.name) == ["Kitchen"])
    }

    @Test("An empty result set clears the list")
    func emptyResultsClearTheList() {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [Self.service(name: "Kitchen", id: "k")])

        var latest: [CastDevice] = .init()
        discovery.onDevicesChanged = { latest = $0 }

        discovery.apply(services: [])

        #expect(discovery.devices.isEmpty)
        #expect(latest.isEmpty)
    }

    @Test("A browse that finds nothing still reports back once")
    func emptyBrowseReportsOnce() {
        let discovery = CastDeviceDiscovery()

        var publications = 0
        discovery.onDevicesChanged = { _ in publications += 1 }

        discovery.apply(services: [])

        // An empty answer is published once so listeners stop waiting for a list that is not coming,
        // and repeated empty answers are not republished.
        #expect(publications == 1)
        discovery.apply(services: [])
        #expect(publications == 1)
    }

    @Test("Stopping keeps the last device list for the menu to reuse")
    func stopKeepsDeviceList() {
        let discovery = CastDeviceDiscovery()
        discovery.apply(services: [Self.service(name: "Living Room TV", id: "l")])

        var publicationCountAfterStop = 0
        discovery.onDevicesChanged = { _ in publicationCountAfterStop += 1 }

        discovery.stop()

        #expect(discovery.devices.map(\.name) == ["Living Room TV"])
        // Stopping must not publish an empty list, which is what used to blank the menu on close.
        #expect(publicationCountAfterStop == 0)
    }

    // MARK: - Fixtures

    private static func identity(for name: String) -> CastServiceIdentity {
        CastServiceIdentity(name: name, type: CastDiscoveryMetadata.serviceType, domain: "local.")
    }

    private static func service(name: String, id: String? = nil, model: String? = nil) -> CastDiscoveredService {
        var txtRecord = ["fn": name]
        if let id {
            txtRecord["id"] = id
        }
        if let model {
            txtRecord["md"] = model
        }

        return CastDiscoveredService(identity: Self.identity(for: name), txtRecord: txtRecord)
    }
}
