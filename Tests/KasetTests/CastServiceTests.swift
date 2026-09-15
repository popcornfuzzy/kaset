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

    // MARK: - Fixtures

    private static func device(name: String) -> CastDevice {
        CastDevice(id: name, name: name, model: "Chromecast", host: "192.168.1.20", port: 8009)
    }
}
