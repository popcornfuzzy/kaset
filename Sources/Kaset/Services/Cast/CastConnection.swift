import Foundation
import Network
import Security

// MARK: - CastConnection

/// A TLS connection to a Cast device's control port.
///
/// Cast devices accept the CASTV2 protocol over TLS on port 8009 with a self-signed certificate.
/// The certificate is not part of the trust model of the protocol, so it is accepted as-is, which
/// is what every Cast sender does.
@MainActor
final class CastConnection: CastMessageChannel {
    /// Errors raised while connecting.
    enum ConnectionError: LocalizedError {
        /// The connection did not become ready in time.
        case timedOut

        /// The connection failed.
        case failed(String)

        /// The channel was closed before it became ready.
        case closed

        var errorDescription: String? {
            switch self {
            case .timedOut: "The Cast device did not respond."
            case let .failed(reason): "Could not reach the Cast device: \(reason)"
            case .closed: "The connection to the Cast device closed."
            }
        }
    }

    private let host: String
    private let port: Int
    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "com.sertacozercan.Kaset.cast.connection")
    private var connection: NWConnection?
    private var framer = CastMessageFramer()
    private var isClosed = false

    /// Last error the network stack reported while connecting.
    ///
    /// Network framework keeps retrying a connection that is `.waiting`, so without this the only
    /// symptom of an unreachable device is a bare timeout.
    private(set) var lastStateError: String?

    /// Called for every complete message received from the device.
    var onMessage: ((CastMessage) -> Void)?

    /// Called once when the channel closes.
    var onClose: ((Swift.Error?) -> Void)?

    /// Called when the TLS connection is ready for the CASTV2 handshake.
    var onReady: (() -> Void)?

    init(host: String, port: Int, service: CastServiceIdentity? = nil) {
        self.host = host
        self.port = port
        self.endpoint = CastControlEndpoint.endpoint(host: host, port: port, service: service)
    }

    /// The local address this connection is using, once it is ready.
    ///
    /// The device has to fetch the audio stream over the same interface it is controlled on, which
    /// makes this the address to advertise rather than a guess based on the device's address.
    var localIPv4Address: String? {
        CastControlEndpoint.ipv4Address(of: self.connection?.currentPath?.localEndpoint)
    }

    /// Opens the connection.
    func connect() {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            CastTLSTrust.accept,
            self.queue
        )

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        // Discovery browses with peer-to-peer enabled, so the connection has to allow it too or a
        // device reachable only over that path could never be dialled.
        parameters.includePeerToPeer = true

        let connection = NWConnection(to: self.endpoint, using: parameters)
        self.connection = connection

        DiagnosticsLogger.cast.info("Connecting to Cast device at \(self.endpoint.diagnosticDescription)")

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }

                switch state {
                case .preparing:
                    DiagnosticsLogger.cast.debug("Preparing connection to \(self.endpoint.diagnosticDescription)")

                case .waiting(let error):
                    // An unreachable address, a blocked port, or a service name that cannot be
                    // resolved all surface here while the connection silently retries.
                    self.lastStateError = error.localizedDescription
                    DiagnosticsLogger.cast.notice(
                        "Waiting to reach \(self.endpoint.diagnosticDescription): \(String(describing: error))"
                    )

                case .ready:
                    DiagnosticsLogger.cast.info("Connected to Cast device at \(self.endpoint.diagnosticDescription)")
                    self.onReady?()
                    self.receiveNext()

                case .failed(let error):
                    self.finish(with: ConnectionError.failed(error.localizedDescription))

                case .cancelled:
                    self.finish(with: nil)

                default:
                    break
                }
            }
        }

        connection.start(queue: self.queue)
    }

    /// Sends a message to the device.
    func send(_ message: CastMessage) {
        guard let connection, !self.isClosed else { return }

        connection.send(content: message.framed(), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                DiagnosticsLogger.cast.debug("Cast send failed: \(error.localizedDescription)")
                self?.finish(with: ConnectionError.failed(error.localizedDescription))
            }
        })
    }

    /// Closes the connection.
    func close() {
        self.isClosed = true
        self.connection?.stateUpdateHandler = nil
        self.connection?.cancel()
        self.connection = nil
        self.framer.reset()
    }

    // MARK: - Receiving

    private func receiveNext() {
        guard let connection, !self.isClosed else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    self.framer.append(data)
                    self.drainMessages()
                }

                if let error {
                    self.finish(with: ConnectionError.failed(error.localizedDescription))
                    return
                }

                if isComplete {
                    self.finish(with: nil)
                    return
                }

                self.receiveNext()
            }
        }
    }

    private func drainMessages() {
        while true {
            do {
                guard let message = try self.framer.nextMessage() else { return }
                self.onMessage?(message)
            } catch {
                DiagnosticsLogger.cast.error("Malformed CASTV2 message: \(error)")
                self.finish(with: error)
                return
            }
        }
    }

    private func finish(with error: Swift.Error?) {
        guard !self.isClosed else { return }
        self.isClosed = true
        self.connection?.stateUpdateHandler = nil
        self.connection?.cancel()
        self.connection = nil
        self.framer.reset()

        if let error {
            DiagnosticsLogger.cast.error("Cast connection closed: \(error.localizedDescription)")
        }
        self.onClose?(error)
    }
}

// MARK: - TLS Trust

/// Trust handling for the Cast control connection.
///
/// Cast devices use self-signed certificates and CASTV2 carries no identity guarantee, which is
/// why every Cast sender ignores the certificate rather than validating it.
///
/// This deliberately lives outside ``CastConnection``: `sec_protocol_verify_t` is a plain
/// Objective-C block, so an inline closure written inside the `@MainActor` connection inherits that
/// isolation and traps as soon as the handshake reaches the certificate, because the TLS stack runs
/// the block on the connection's own queue.
/// `CastTLSTrust.accept` is asserted to stay non-isolated in `CastTLSIsolationTests`.
enum CastTLSTrust {
    /// Accepts whatever certificate the device presents.
    static func accept(
        _: sec_protocol_metadata_t,
        _: sec_trust_t,
        _ completeVerification: sec_protocol_verify_complete_t
    ) {
        completeVerification(true)
    }
}

// MARK: - CastControlEndpoint

/// Maps a discovered device to the endpoint that reaches its control port.
///
/// Both ``CastDevice/host`` and ``CastServiceIdentity`` can describe a device, but only one of them
/// is dialable: a Bonjour instance name is not a host, and asking the network stack to resolve it
/// as one stalls until it times out.
enum CastControlEndpoint {
    /// Cast control port used when a device does not name one.
    static let defaultPort: UInt16 = 8009

    /// Builds the endpoint for a device.
    ///
    /// A device found by browsing is reached through its service record; anything else has to be
    /// dialled by address.
    static func endpoint(host: String, port: Int, service: CastServiceIdentity?) -> NWEndpoint {
        if let service {
            return .service(name: service.name, type: service.type, domain: service.domain, interface: nil)
        }

        let resolvedPort = NWEndpoint.Port(rawValue: port > 0 ? UInt16(clamping: port) : Self.defaultPort) ?? .any
        return .hostPort(host: NWEndpoint.Host(host), port: resolvedPort)
    }

    /// Reads the IPv4 address out of an endpoint, when it has one.
    static func ipv4Address(of endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        guard case let .ipv4(address) = host else { return nil }
        return "\(address)"
    }
}

// MARK: - NWEndpoint Logging

private extension NWEndpoint {
    /// Description used in log messages.
    var diagnosticDescription: String {
        switch self {
        case let .service(name, type, domain, _):
            "\(name) (\(type).\(domain))"
        case let .hostPort(host, port):
            "\(host):\(port)"
        default:
            String(describing: self)
        }
    }
}
