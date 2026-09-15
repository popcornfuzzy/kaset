import Foundation
import Network

// MARK: - CastDeviceBrowsing

/// What ``CastService`` needs from a Cast device browser.
///
/// Discovery is the only part of casting that talks to the network before a device has been
/// chosen, so keeping it behind this seam lets the Cast menu's behaviour be tested without mDNS.
@MainActor
protocol CastDeviceBrowsing: AnyObject {
    /// Devices the browser knows about.
    var devices: [CastDevice] { get }

    /// Called whenever the visible device list changes.
    var onDevicesChanged: (([CastDevice]) -> Void)? { get set }

    /// Called when browsing fails.
    var onError: ((String) -> Void)? { get set }

    /// Starts browsing.
    func start()

    /// Stops browsing.
    func stop()
}

// MARK: - CastDiscoveredService

/// A Cast service the Bonjour browser reported.
///
/// `NWBrowser.Result` cannot be built outside Network framework, so the browser's answer is copied
/// into this value type. Discovery then works on plain values, which is also what makes the
/// publication path testable without a device on the network.
struct CastDiscoveredService: Equatable, Sendable {
    /// Bonjour coordinates of the service.
    let identity: CastServiceIdentity

    /// The service's TXT record, which carries the friendly name and model the menu shows.
    let txtRecord: [String: String]

    /// Bonjour instance name, e.g. `Living Room TV._googlecast._tcp.local.`.
    var instanceName: String {
        "\(self.identity.name).\(self.identity.type).\(self.identity.domain)"
    }

    /// Reads a browse result, or `nil` when it is not a Bonjour service.
    init?(result: NWBrowser.Result) {
        guard case let .service(serviceName, serviceType, domain, _) = result.endpoint else { return nil }
        guard case let .bonjour(record) = result.metadata else { return nil }

        self.identity = CastServiceIdentity(name: serviceName, type: serviceType, domain: domain)
        self.txtRecord = record.dictionary
    }

    init(identity: CastServiceIdentity, txtRecord: [String: String]) {
        self.identity = identity
        self.txtRecord = txtRecord
    }
}

// MARK: - CastDeviceDiscovery

/// Finds Cast devices on the local network.
///
/// Cast devices advertise a `_googlecast._tcp` Bonjour service. Browsing gives the friendly name,
/// model, and device id; the device is then dialed through its Bonjour identity, whose address
/// lives in the service's SRV record and is resolved by Network framework itself. The advertised
/// instance name is kept as the device's host, and is only used for logging and as a fallback.
@MainActor
final class CastDeviceDiscovery: CastDeviceBrowsing {
    /// Default Cast control port.
    static let defaultControlPort = 8009

    private let queue = DispatchQueue(label: "com.sertacozercan.Kaset.cast.discovery")
    private let port: Int
    private var browser: NWBrowser?

    /// Devices keyed by Bonjour instance name, which is what mDNS re-announces and removals use.
    private var devicesByInstance: [String: CastDevice] = [:]

    private var registry = CastDeviceRegistry()

    /// When the current browse started, used to report how long the first device took to show up.
    private var browseStartedAt: ContinuousClock.Instant?

    /// Whether the current browse has published anything, including an empty list.
    ///
    /// The Cast menu needs to tell "mDNS has not answered yet" apart from "there is nothing here",
    /// and both look like an empty list.
    private var hasReportedThisBrowse = false

    /// Called whenever the visible device list changes.
    var onDevicesChanged: (([CastDevice]) -> Void)?

    /// Called when browsing fails.
    var onError: ((String) -> Void)?

    /// Devices currently known to the browser, ordered by name.
    ///
    /// These are kept after browsing stops, so the Cast menu can show the last known devices while
    /// a fresh browse answers.
    var devices: [CastDevice] {
        self.registry.devices
    }

    init(port: Int = CastDeviceDiscovery.defaultControlPort) {
        self.port = port
    }

    /// Starts browsing. Calling this while already browsing has no effect.
    func start() {
        guard self.browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CastDiscoveryMetadata.serviceType, domain: nil),
            using: parameters
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.update(with: results)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed(let error):
                    DiagnosticsLogger.cast.error("Cast discovery failed: \(error.localizedDescription)")
                    self?.onError?(error.localizedDescription)
                case .cancelled:
                    // A cancelled browse reports nothing more, so drop the entries and let the next
                    // browse answer from scratch. The published list is deliberately left alone: it
                    // is what the menu shows until then.
                    self?.devicesByInstance.removeAll()
                    self?.hasReportedThisBrowse = false
                default:
                    break
                }
            }
        }

        self.browser = browser
        self.browseStartedAt = .now
        self.hasReportedThisBrowse = false
        browser.start(queue: self.queue)
    }

    /// Stops browsing.
    ///
    /// Discovered devices are kept so the menu can show them again immediately; the next browse
    /// replaces them, removing anything that is no longer advertised.
    func stop() {
        self.browser?.stateUpdateHandler = nil
        self.browser?.browseResultsChangedHandler = nil
        self.browser?.cancel()
        self.browser = nil

        self.browseStartedAt = nil
        self.hasReportedThisBrowse = false
        self.devicesByInstance.removeAll()
    }

    // MARK: - Results

    private func update(with results: Set<NWBrowser.Result>) {
        self.apply(services: results.compactMap(CastDiscoveredService.init(result:)))
    }

    /// Publishes the services the browser currently sees.
    ///
    /// Everything the menu needs — name, model, device id — comes from the TXT record, so a device
    /// is published the moment mDNS reports it and nothing here is asynchronous.
    ///
    /// Resolving an address at this point would hold every device back by five seconds: a Bonjour
    /// service instance is not a hostname, so `getaddrinfo` on one has no answer and spends the
    /// whole mDNS timeout before failing. The control connection dials the service endpoint
    /// instead, so a numeric address is only ever cosmetic.
    func apply(services: [CastDiscoveredService]) {
        var nextDevices: [String: CastDevice] = [:]

        for service in services {
            guard let device = CastDiscoveryMetadata.device(
                from: service.txtRecord,
                host: service.identity.name,
                port: self.port,
                service: service.identity
            ) else { continue }

            nextDevices[service.instanceName] = device
        }

        self.devicesByInstance = nextDevices
        self.publishDevices()
    }

    private func publishDevices() {
        var nextRegistry = CastDeviceRegistry()
        for device in self.devicesByInstance.values {
            nextRegistry.upsert(device)
        }

        // The first answer of a browse is published even when it is empty, so listeners stop waiting
        // for a device list that is never coming. Later unchanged answers are not republished.
        let isFirstAnswer = !self.hasReportedThisBrowse
        guard isFirstAnswer || nextRegistry.devices != self.registry.devices else { return }

        self.hasReportedThisBrowse = true
        self.registry = nextRegistry

        if let startedAt = self.browseStartedAt, !nextRegistry.devices.isEmpty {
            self.browseStartedAt = nil
            DiagnosticsLogger.cast.info(
                "Found \(nextRegistry.devices.count) Cast device(s) \(Self.describe(.now - startedAt)) after browsing started"
            )
        } else {
            DiagnosticsLogger.cast.debug("Discovered \(nextRegistry.devices.count) Cast device(s)")
        }

        self.onDevicesChanged?(nextRegistry.devices)
    }

    /// Formats a duration for the discovery log, e.g. `0.42s`.
    private static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }
}
