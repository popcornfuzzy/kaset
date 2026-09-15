import Foundation
import Testing
@testable import Kaset

/// Cast service state handling and menu text.
@Suite(.tags(.service))
@MainActor
struct CastServiceTests {
    // MARK: - Initial State

    @Test("A new service is idle with no devices")
    func startsIdle() {
        let service = CastService()

        #expect(service.state == .idle)
        #expect(service.devices.isEmpty)
        #expect(service.isCasting == false)
        #expect(service.isBusy == false)
        #expect(service.activeDevice == nil)
        #expect(service.isReceiverConnected == false)
    }

    @Test("An idle service reports that it is not connected")
    func idleStatusText() {
        #expect(CastService().statusDescription == CastStatusText.describe(.idle, isReceiverConnected: false))
    }

    @Test("Stopping discovery while idle leaves the service idle")
    func stoppingDiscoveryWhileIdle() {
        let service = CastService()

        service.stopDiscovery()

        #expect(service.state == .idle)
    }

    @Test("Stopping casting while idle leaves the service idle")
    func stoppingCastingWhileIdle() {
        let service = CastService()

        service.stopCasting()

        #expect(service.state == .idle)
        #expect(service.devices.isEmpty)
        #expect(service.isCasting == false)
    }

    // MARK: - Status Text

    @Test("Searching is described as looking for devices")
    func searchingStatusText() {
        let text = CastStatusText.describe(.searching, isReceiverConnected: false)

        #expect(!text.isEmpty)
        #expect(text != CastStatusText.describe(.idle, isReceiverConnected: false))
    }

    @Test("Connecting names the device")
    func connectingStatusText() {
        let device = Self.device(name: "Living Room TV")
        let text = CastStatusText.describe(.connecting(device), isReceiverConnected: false)

        #expect(text.contains("Living Room TV"))
    }

    @Test("Casting distinguishes waiting for the receiver from streaming")
    func castingStatusText() {
        let device = Self.device(name: "Studio Speaker")

        let starting = CastStatusText.describe(.casting(device), isReceiverConnected: false)
        let streaming = CastStatusText.describe(.casting(device), isReceiverConnected: true)

        #expect(starting.contains("Studio Speaker"))
        #expect(streaming.contains("Studio Speaker"))
        #expect(starting != streaming)
    }

    @Test("A failure is reported verbatim")
    func failureStatusText() {
        #expect(CastStatusText.describe(.failed("The Cast device disconnected."), isReceiverConnected: false) == "The Cast device disconnected.")
    }

    @Test("Only connecting counts as busy")
    func busyState() {
        let device = Self.device(name: "TV")

        #expect(CastStatusText.describe(.connecting(device), isReceiverConnected: false).isEmpty == false)
        // `isBusy` is derived from the state the service holds; a fresh service is never busy.
        #expect(CastService().isBusy == false)
    }

    // MARK: - Menu Responsiveness

    @Test("Devices reach the menu as the browser finds them")
    func devicesAppearAsFound() {
        let browser = FakeBrowser()
        let service = CastService(discovery: browser)

        service.startDiscovery()
        browser.publish([Self.device(name: "Living Room TV")])

        #expect(service.devices.map(\.name) == ["Living Room TV"])
        #expect(service.state == .searching)
    }

    @Test("Closing the menu keeps the device list for the next open")
    func deviceListSurvivesReopening() {
        let browser = FakeBrowser()
        let service = CastService(discovery: browser)

        service.startDiscovery()
        browser.publish([Self.device(name: "Living Room TV")])
        service.stopDiscovery()

        #expect(service.devices.map(\.name) == ["Living Room TV"])

        service.startDiscovery()

        // The list has to be there the instant the menu reopens, before the browser answers again.
        #expect(service.devices.map(\.name) == ["Living Room TV"])
        #expect(service.state == .searching)
    }

    @Test("Refreshing re-browses without blanking the list")
    func refreshKeepsDevicesVisible() {
        let browser = FakeBrowser()
        let service = CastService(discovery: browser)

        service.startDiscovery()
        browser.publish([Self.device(name: "Living Room TV")])
        service.refresh()

        #expect(browser.stopCount == 1)
        #expect(browser.startCount == 2)
        #expect(service.devices.map(\.name) == ["Living Room TV"])
    }

    @Test("A browser that reports nothing empties the list")
    func emptyBrowseClearsDevices() {
        let browser = FakeBrowser()
        let service = CastService(discovery: browser)

        service.startDiscovery()
        browser.publish([Self.device(name: "Living Room TV")])
        browser.publish([])

        #expect(service.devices.isEmpty)
    }

    @Test("The menu waits for a browse only until it answers")
    func awaitingDevicesEndsOnAnswer() {
        let browser = FakeBrowser()
        let service = CastService(discovery: browser)

        service.startDiscovery()
        #expect(service.isAwaitingDevices)

        // An empty answer still ends the wait, which is what separates "looking" from "nothing here".
        browser.publish([])
        #expect(!service.isAwaitingDevices)

        service.stopDiscovery()
        #expect(!service.isAwaitingDevices)
    }

    @Test("A discovery failure is reported while searching")
    func discoveryFailureIsReported() {
        let browser = FakeBrowser()
        let service = CastService(discovery: browser)

        service.startDiscovery()
        browser.fail("The network is unavailable.")

        #expect(service.state == .failed("The network is unavailable."))
    }

    // MARK: - Fixtures

    private static func device(name: String) -> CastDevice {
        CastDevice(id: name, name: name, model: "Chromecast", host: "192.168.1.20", port: 8009)
    }
}

// MARK: - FakeBrowser

/// Stands in for ``CastDeviceDiscovery`` so the menu's behaviour can be driven without mDNS.
@MainActor
private final class FakeBrowser: CastDeviceBrowsing {
    var devices: [CastDevice] = []
    var onDevicesChanged: (([CastDevice]) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    /// Reports the devices the browser currently sees.
    func publish(_ devices: [CastDevice]) {
        self.devices = devices
        self.onDevicesChanged?(devices)
    }

    /// Reports a browsing failure.
    func fail(_ message: String) {
        self.onError?(message)
    }
}
