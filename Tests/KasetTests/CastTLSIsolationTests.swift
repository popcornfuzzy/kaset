import Security
import Testing
@testable import Kaset

/// Guards the isolation of blocks that the network stack calls on its own queues.
///
/// `sec_protocol_verify_t` is a plain Objective-C block, and an inline closure written inside a
/// `@MainActor` type inherits that isolation. The TLS stack does not call the block on the main
/// actor, so an isolated block is a `SIGTRAP` crash the moment the handshake reaches the
/// certificate, which is what happened when the Cast connection was first pointed at a device.
@Suite(.tags(.service))
struct CastTLSIsolationTests {
    @Test("The Cast certificate acceptor is safe to call from any thread")
    func certificateAcceptorIsNotIsolated() {
        // A main-actor-isolated function cannot be converted to a `@Sendable` function type, so
        // this assignment is the assertion: it stops compiling if isolation creeps back in.
        let acceptor: @Sendable (
            sec_protocol_metadata_t,
            sec_trust_t,
            sec_protocol_verify_complete_t
        ) -> Void = CastTLSTrust.accept

        _ = acceptor
    }
}
