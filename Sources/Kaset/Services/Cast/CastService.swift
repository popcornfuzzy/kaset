import Foundation
import Observation

// MARK: - CastService

/// Manages casting Kaset's audio to a Google Cast device.
///
/// Casting here means Kaset stays the player and becomes the media source: the track keeps playing
/// in the WebView, its audio is captured, and the Cast device plays that stream. Kaset's queue,
/// seek, and track changes therefore keep working unchanged while casting.
@MainActor
@Observable
final class CastService {
    /// What Kaset is doing on the Cast side.
    enum State: Equatable {
        /// Not casting and not looking for devices.
        case idle

        /// Browsing the network for Cast devices.
        case searching

        /// Connecting to a device and preparing the stream.
        case connecting(CastDevice)

        /// Streaming audio to a device.
        case casting(CastDevice)

        /// The last attempt failed.
        case failed(String)
    }

    /// How long to wait for a device to answer before giving up.
    ///
    /// This has to cover a TLS handshake, a virtual connection, and the device launching or
    /// resuming its receiver application, which is slow on a cold device.
    private static let connectionTimeout: Duration = .seconds(20)

    private let discovery: CastDeviceDiscovery
    private var connection: CastConnection?
    private var session: CastReceiverSession?
    private var streamer: CastAudioStreamer?
    private var timeoutTask: Task<Void, Never>?

    /// Guards against teardown callbacks failing the same attempt twice.
    private var isFailing = false

    /// Current cast state.
    private(set) var state: State = .idle

    /// Devices currently visible on the network.
    private(set) var devices: [CastDevice] = []

    /// Whether the device is reading the stream.
    private(set) var isReceiverConnected = false

    init(discovery: CastDeviceDiscovery = CastDeviceDiscovery()) {
        self.discovery = discovery

        self.discovery.onDevicesChanged = { [weak self] devices in
            self?.devices = devices
        }

        self.discovery.onError = { [weak self] message in
            guard let self, case .searching = self.state else { return }
            self.state = .failed(message)
        }
    }

    /// The device being cast to or connected to, if any.
    var activeDevice: CastDevice? {
        switch self.state {
        case let .connecting(device), let .casting(device):
            device
        default:
            nil
        }
    }

    /// Whether audio is currently being streamed to a device.
    var isCasting: Bool {
        if case .casting = self.state {
            return true
        }
        return false
    }

    /// Whether a connection attempt is in flight.
    var isBusy: Bool {
        if case .connecting = self.state {
            return true
        }
        return false
    }

    /// Short description of the current state, shown in the Cast menu.
    var statusDescription: String {
        CastStatusText.describe(self.state, isReceiverConnected: self.isReceiverConnected)
    }

    // MARK: - Discovery

    /// Starts browsing for Cast devices.
    func startDiscovery() {
        guard !self.isCasting else { return }

        if case .failed = self.state {
            self.state = .idle
        }

        self.devices = []
        self.discovery.start()

        if case .idle = self.state {
            self.state = .searching
        }
    }

    /// Stops browsing for devices.
    func stopDiscovery() {
        self.discovery.stop()

        if case .searching = self.state {
            self.state = .idle
        }
    }

    /// Restarts browsing, used by the refresh button in the Cast menu.
    func refresh() {
        self.discovery.stop()
        self.devices = []
        self.startDiscovery()
    }

    // MARK: - Casting

    /// Casts to a device.
    func cast(to device: CastDevice) {
        self.teardown(keepDiscovery: false)

        self.state = .connecting(device)

        let connection = CastConnection(host: device.host, port: device.port, service: device.service)
        self.connection = connection

        let session = CastReceiverSession(channel: connection)
        self.session = session

        session.onPhaseChanged = { [weak self] phase in
            self?.handle(phase: phase, device: device)
        }

        connection.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // The device fetches the stream over the interface it is controlled on, so the
                // address comes from this connection rather than from the device's own address.
                let localAddress = self.connection?.localIPv4Address

                // The session owns the channel's close handling, so it starts once the socket is up.
                self.session?.start()
                await self.beginStreaming(device: device, preferredLocalAddress: localAddress)
            }
        }

        self.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.connectionTimeout)
            guard !Task.isCancelled, let self, case .connecting = self.state else { return }

            // A device that never answered is usually unreachable rather than silent, and the
            // network stack knows why. Reporting the two cases differently keeps a blocked
            // connection from looking like a receiver that ignored us.
            if let detail = self.connection?.lastStateError {
                DiagnosticsLogger.cast.error("Never reached \(device.name): \(detail)")
                self.fail(String(localized: "\(device.name) could not be reached."), device: device)
                return
            }
            self.fail(String(localized: "\(device.name) did not respond."), device: device)
        }

        connection.connect()
    }

    /// Stops casting and tears the stream down.
    func stopCasting() {
        // Clearing the state first marks the stop as deliberate, so the session's `.stopped`
        // callback does not report it as a disconnect.
        self.state = .idle
        self.teardown(keepDiscovery: true)
    }

    // MARK: - Streaming

    private func beginStreaming(device: CastDevice, preferredLocalAddress: String?) async {
        guard case .connecting = self.state else { return }

        do {
            let streamer = CastAudioStreamer()
            streamer.onReceiverConnectionChanged = { [weak self] isConnected in
                self?.isReceiverConnected = isConnected
            }

            let streamURL = try await streamer.start(
                deviceHost: device.host,
                preferredLocalAddress: preferredLocalAddress
            )
            self.streamer = streamer

            self.session?.prepareStream(url: streamURL.absoluteString)
        } catch {
            DiagnosticsLogger.cast.error("Could not start casting: \(error.localizedDescription)")
            self.fail(error.localizedDescription, device: device)
        }
    }

    private func handle(phase: CastReceiverSession.Phase, device: CastDevice) {
        switch phase {
        case .connecting, .launching:
            break

        case .buffering, .playing:
            guard case .connecting = self.state else { return }
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.state = .casting(device)
            DiagnosticsLogger.cast.info("Casting to \(device.name)")

        case let .failed(message):
            self.fail(message, device: device)

        case .stopped:
            // Reaching this with an active device means the device ended the session on its own.
            if self.isCasting || self.activeDevice != nil {
                self.fail(String(localized: "The Cast device disconnected."), device: device)
            }
        }
    }

    // MARK: - Teardown

    private func fail(_ message: String, device: CastDevice) {
        guard !self.isFailing else { return }
        self.isFailing = true
        defer { self.isFailing = false }

        DiagnosticsLogger.cast.error("Casting to \(device.name) failed: \(message)")
        self.teardown(keepDiscovery: false)
        self.state = .failed(message)
    }

    private func teardown(keepDiscovery: Bool) {
        self.timeoutTask?.cancel()
        self.timeoutTask = nil

        let session = self.session
        let connection = self.connection
        let streamer = self.streamer
        self.session = nil
        self.connection = nil
        self.streamer = nil

        // Detach the callbacks before stopping these objects: stopping the session reports a
        // `.stopped` phase, and the connection reports its own close, both of which would fail
        // this attempt a second time for a teardown the user asked for.
        session?.onPhaseChanged = nil
        connection?.onClose = nil
        streamer?.onReceiverConnectionChanged = nil

        session?.stop()
        connection?.close()
        streamer?.stop()

        self.isReceiverConnected = false

        if !keepDiscovery {
            self.discovery.stop()
        }
    }
}

// MARK: - CastStatusText

/// Turns cast state into the text shown in the Cast menu.
///
/// Kept separate from ``CastService`` so every state can be asserted without a device on the
/// network.
enum CastStatusText {
    /// Describes a cast state.
    static func describe(_ state: CastService.State, isReceiverConnected: Bool) -> String {
        switch state {
        case .idle:
            String(localized: "Not connected")
        case .searching:
            String(localized: "Looking for devices…")
        case let .connecting(device):
            String(localized: "Connecting to \(device.name)…")
        case let .casting(device):
            isReceiverConnected
                ? String(localized: "Streaming to \(device.name)")
                : String(localized: "Starting \(device.name)…")
        case let .failed(message):
            message
        }
    }
}
