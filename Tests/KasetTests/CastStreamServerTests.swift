import Foundation
import Testing
@testable import Kaset

/// The local audio stream as the Cast receiver experiences it.
///
/// These drive a real HTTP client against the server instead of its value types, because the contract
/// that decides whether casting plays is the bytes a receiver receives: an endless chunked
/// `audio/aac` body that starts with the audio captured before it connected.
@Suite(.tags(.service, .integration))
struct CastStreamServerTests {
    @Test("Streams audio to a connected receiver")
    @MainActor
    func streamsAudioToReceiver() async throws {
        let server = LocalAudioStreamServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(server.streamPath)"))
        let audio = Data([0xFF, 0xF1, 0x4C, 0x80, 0x00, 0x00, 0xFC, 0x11, 0x22, 0x33])

        // The receiver dials in first and the audio follows, which is the order the Cast device hits:
        // it loads the URL, keeps the connection open, and waits for Kaset to play something.
        let streaming = Task { @MainActor in
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 5))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "audio/aac")
            // `Transfer-Encoding` is hop-by-hop and is stripped by the client once it de-chunks, so the
            // framing is proven by the payload below arriving intact.
            return try await self.receive(byteCount: audio.count, from: bytes)
        }

        try await self.waitUntil { server.streamingClientCount > 0 }
        #expect(server.streamingClientCount == 1)
        server.enqueue(audio)

        #expect(try await streaming.value == audio)
    }

    @Test("Starts a receiver with the audio captured before it connected")
    @MainActor
    func startsReceiverWithPendingAudio() async throws {
        let server = LocalAudioStreamServer()
        let port = try await server.start()
        defer { server.stop() }

        // Audio captured while nothing was streaming is held, so a receiver that connects late starts
        // near the live edge rather than with silence.
        let audio = Data([0xFF, 0xF1, 0x4C, 0x80, 0x00, 0x00, 0xFC, 0xAA, 0xBB])
        server.enqueue(audio)

        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(server.streamPath)"))
        let (bytes, _) = try await URLSession.shared.bytes(from: url)

        #expect(try await self.receive(byteCount: audio.count, from: bytes) == audio)
    }

    @Test("Rejects a request for an unknown path")
    @MainActor
    func rejectsUnknownPath() async throws {
        let server = LocalAudioStreamServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/something-else"))
        let (_, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(server.streamingClientCount == 0)
    }

    // MARK: - Helpers

    /// Reads exactly `byteCount` bytes from a streaming response.
    @MainActor
    private func receive(byteCount: Int, from bytes: URLSession.AsyncBytes) async throws -> Data {
        var received = Data()
        for try await byte in bytes {
            received.append(byte)
            if received.count >= byteCount { break }
        }
        return received
    }

    /// Waits for a condition, so tests do not race the server's connection handling.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
