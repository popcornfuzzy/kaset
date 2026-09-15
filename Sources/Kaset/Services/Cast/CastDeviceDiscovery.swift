import Foundation
import Network

// MARK: - CastDeviceDiscovery

/// Finds Cast devices on the local network.
///
/// Cast devices advertise a `_googlecast._tcp` Bonjour service. Browsing gives the friendly name,
/// model, and device id; the device address is resolved from the advertised instance name. The
/// default Cast control port is used, which is what every device listens on.
@MainActor
final class CastDeviceDiscovery {
    /// Default Cast control port.
    static let defaultControlPort = 8009

    private let queue = DispatchQueue(label: "com.sertacozercan.Kaset.cast.discovery")
    private let port: Int
    private var browser: NWBrowser?
    private var registry = CastDeviceRegistry()
    private var resolvedDevices: [String: CastDevice] = [:]
    private var visibleInstances: Set<String> = []

    /// Called whenever the visible device list changes.
    var onDevicesChanged: (([CastDevice]) -> Void)?

    /// Called when browsing fails.
    var onError: ((String) -> Void)?

    /// Devices currently visible on the network, ordered by name.
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
                    self?.visibleInstances.removeAll()
                    self?.resolvedDevices.removeAll()
                    self?.publishDevices()
                default:
                    break
                }
            }
        }

        self.browser = browser
        browser.start(queue: self.queue)
    }

    /// Stops browsing and clears the device list.
    func stop() {
        self.browser?.stateUpdateHandler = nil
        self.browser?.browseResultsChangedHandler = nil
        self.browser?.cancel()
        self.browser = nil

        self.visibleInstances.removeAll()
        self.resolvedDevices.removeAll()
        self.publishDevices()
    }

    // MARK: - Results

    private func update(with results: Set<NWBrowser.Result>) {
        var instances: Set<String> = []

        for result in results {
            guard case let .service(serviceName, serviceType, domain, _) = result.endpoint else { continue }

            let instanceName = "\(serviceName).\(serviceType).\(domain)"
            guard let txtRecord = self.txtRecord(from: result) else { continue }

            // The service instance is what the connection has to dial: its address comes from the
            // SRV record, which only a service endpoint resolves.
            let identity = CastServiceIdentity(name: serviceName, type: serviceType, domain: domain)

            instances.insert(instanceName)

            // A device that has already been resolved keeps its address; mDNS re-announces would
            // otherwise trigger repeated lookups.
            if self.resolvedDevices[instanceName] != nil {
                continue
            }

            let hostname = instanceName
            let port = self.port
            Task.detached(priority: .utility) { [weak self] in
                let address = CastDeviceDiscovery.resolveIPv4(hostname: hostname, port: port) ?? hostname

                await MainActor.run { [weak self] in
                    guard let self, self.visibleInstances.contains(instanceName) else { return }
                    guard let device = CastDiscoveryMetadata.device(
                        from: txtRecord,
                        host: address,
                        port: port,
                        service: identity
                    ) else { return }

                    self.resolvedDevices[instanceName] = device
                    self.publishDevices()
                }
            }
        }

        self.visibleInstances = instances
        self.resolvedDevices = self.resolvedDevices.filter { instances.contains($0.key) }
        self.publishDevices()
    }

    private func txtRecord(from result: NWBrowser.Result) -> [String: String]? {
        guard case let .bonjour(record) = result.metadata else { return nil }
        return record.dictionary
    }

    private func publishDevices() {
        var nextRegistry = CastDeviceRegistry()
        for instanceName in self.visibleInstances {
            guard let device = self.resolvedDevices[instanceName] else { continue }
            nextRegistry.upsert(device)
        }

        guard nextRegistry.devices != self.registry.devices else { return }

        self.registry = nextRegistry
        DiagnosticsLogger.cast.debug("Discovered \(nextRegistry.devices.count) Cast device(s)")
        self.onDevicesChanged?(nextRegistry.devices)
    }

    // MARK: - Address Resolution

    /// Resolves a Bonjour instance name to a numeric IPv4 address.
    ///
    /// This is a convenience for logs only: the control connection uses the device's
    /// ``CastServiceIdentity`` rather than whichever address this happens to return. Returns `nil`
    /// when the name cannot be resolved, in which case the caller keeps the Bonjour name as the
    /// device address.
    nonisolated static func resolveIPv4(hostname: String, port: Int) -> String? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, String(port), &hints, &result) == 0, let firstResult = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        guard let address = firstResult.pointee.ai_addr else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            address,
            firstResult.pointee.ai_addrlen,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { return nil }

        return String(cString: host)
    }
}
