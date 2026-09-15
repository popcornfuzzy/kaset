import Foundation

// MARK: - CastMessageChannel

/// A bidirectional CASTV2 message channel.
///
/// The session logic only needs to send and receive messages, so it is written against this
/// protocol. Production uses ``CastConnection``, which speaks TLS to the device; tests drive a fake
/// channel to exercise the handshake without a Chromecast on the network.
@MainActor
protocol CastMessageChannel: AnyObject {
    /// Called for every complete message received from the device.
    var onMessage: ((CastMessage) -> Void)? { get set }

    /// Called once when the channel closes, with an error when the close was not deliberate.
    var onClose: ((Swift.Error?) -> Void)? { get set }

    /// Sends a message to the device.
    func send(_ message: CastMessage)

    /// Closes the channel.
    func close()
}
