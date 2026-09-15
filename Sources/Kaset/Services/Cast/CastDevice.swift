import Foundation

// MARK: - CastServiceIdentity

/// Bonjour coordinates of a discovered Cast device.
///
/// A Bonjour service instance is not a hostname: its address lives in the service's SRV record, so
/// resolving the instance name as a host does not work. Network framework performs that resolution
/// itself for `.service` endpoints, which is why a device carries these coordinates instead of only
/// an address.
struct CastServiceIdentity: Equatable, Hashable, Sendable {
    /// Service instance name, e.g. `Chromecast-Ultra-1234`.
    let name: String

    /// Service type, e.g. `_googlecast._tcp`.
    let type: String

    /// Service domain, e.g. `local.`.
    let domain: String
}

// MARK: - CastDevice

/// A Cast device found on the local network.
struct CastDevice: Identifiable, Equatable, Hashable, Sendable {
    /// Stable device identifier. Prefers the mDNS TXT `id` field and falls back to the socket address.
    let id: String

    /// Human-readable device name shown in the Cast menu.
    let name: String

    /// Device model from the mDNS TXT record, when the device advertises one.
    let model: String?

    /// Host address of the device.
    ///
    /// Devices found over Bonjour also carry ``service``, which is what the control connection
    /// dials; this address is then only used for logging and as a fallback.
    let host: String

    /// Cast control port. Cast devices listen on 8009 by default.
    let port: Int

    /// Bonjour service coordinates, present for every device found by browsing.
    var service: CastServiceIdentity? = nil

    /// The address the device is reachable at, used in log messages.
    var displayAddress: String {
        "\(self.host):\(self.port)"
    }
}

// MARK: - Discovery Metadata

/// Parses the mDNS TXT record that Cast devices advertise.
///
/// Cast devices publish a `_googlecast._tcp` Bonjour service whose TXT record carries the
/// friendly name (`fn`), model (`md`), and unique device id (`id`).
enum CastDiscoveryMetadata {
    /// Keys Kaset reads out of a Cast TXT record.
    enum TXTKey {
        static let friendlyName = "fn"
        static let model = "md"
        static let deviceID = "id"
    }

    /// The Bonjour service type Cast devices advertise.
    static let serviceType = "_googlecast._tcp"

    /// Builds a device from a TXT record.
    ///
    /// Returns `nil` when the record has no usable name, since a nameless entry cannot be offered
    /// in the Cast menu.
    static func device(
        from txtRecord: [String: String],
        host: String,
        port: Int,
        service: CastServiceIdentity? = nil
    ) -> CastDevice? {
        let name = txtRecord[TXTKey.friendlyName]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }

        let model = txtRecord[TXTKey.model]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let advertisedID = txtRecord[TXTKey.deviceID]?.trimmingCharacters(in: .whitespacesAndNewlines)

        let id = if let advertisedID, !advertisedID.isEmpty {
            advertisedID
        } else {
            "\(host):\(port)"
        }

        return CastDevice(
            id: id,
            name: name,
            model: model?.isEmpty == true ? nil : model,
            host: host,
            port: port,
            service: service
        )
    }
}

// MARK: - CastDeviceRegistry

/// Keeps the discovered device list ordered and free of duplicates.
///
/// mDNS re-announces devices regularly, and a device can move between addresses, so the registry
/// updates existing entries by identifier instead of appending duplicates.
struct CastDeviceRegistry: Equatable, Sendable {
    private(set) var devices: [CastDevice] = []

    /// Adds or refreshes a device, returning `true` when the visible list changed.
    @discardableResult
    mutating func upsert(_ device: CastDevice) -> Bool {
        if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
            guard self.devices[index] != device else { return false }
            self.devices[index] = device
        } else {
            self.devices.append(device)
        }

        self.devices.sort { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return true
    }

    /// Removes a device by identifier, returning `true` when something was removed.
    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let index = self.devices.firstIndex(where: { $0.id == id }) else { return false }
        self.devices.remove(at: index)
        return true
    }

    /// Removes every device, used when discovery restarts.
    mutating func removeAll() {
        self.devices.removeAll()
    }
}
