import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct AppleMusicCanvasProviderTests {
    // MARK: - Motion video extraction

    @Test("videoURL prefers motionDetailRaw, then falls back to any nested video")
    func videoURLPreferenceAndFallback() {
        let data: [String: Any] = [
            "motionDetailRaw": ["video": "https://example.com/raw.m3u8"],
            "motionDetailSquare": ["video": "https://example.com/square.m3u8"],
        ]
        #expect(AppleMusicCanvasProvider.videoURL(in: data)?.absoluteString == "https://example.com/raw.m3u8")

        let onlyFallback: [String: Any] = ["someCustomKey": ["video": "https://example.com/custom.m3u8"]]
        #expect(AppleMusicCanvasProvider.videoURL(in: onlyFallback)?.absoluteString == "https://example.com/custom.m3u8")

        #expect(AppleMusicCanvasProvider.videoURL(in: [:]) == nil)
        #expect(AppleMusicCanvasProvider.videoURL(in: ["motionDetailRaw": ["video": ""]]) == nil)
    }

    @Test("extractEditorialVideoURL prefers editorialVideo over editorialArtwork")
    func prefersEditorialVideo() {
        let attributes: [String: Any] = [
            "editorialVideo": ["motionDetailTall": ["video": "https://example.com/video.m3u8"]],
            "editorialArtwork": ["motionDetailTall": ["video": "https://example.com/artwork.m3u8"]],
        ]
        #expect(
            AppleMusicCanvasProvider.extractEditorialVideoURL(from: attributes)?.absoluteString
                == "https://example.com/video.m3u8"
        )
    }

    @Test("extractEditorialVideoURL falls back to editorialArtwork")
    func fallsBackToEditorialArtwork() {
        let attributes: [String: Any] = [
            "editorialArtwork": ["motionSquareVideo1x1": ["video": "https://example.com/artwork.m3u8"]],
        ]
        #expect(
            AppleMusicCanvasProvider.extractEditorialVideoURL(from: attributes)?.absoluteString
                == "https://example.com/artwork.m3u8"
        )
        #expect(AppleMusicCanvasProvider.extractEditorialVideoURL(from: [:]) == nil)
    }

    // MARK: - Token handling

    @Test("decodeBase64URL handles the JWT-safe alphabet")
    func decodesBase64URL() {
        let payload = Data(#"{"iss":"apple.com"}"#.utf8).base64EncodedString()
        let jwtSafe = payload
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = AppleMusicCanvasProvider.decodeBase64URL(jwtSafe)
        #expect(decoded != nil)
        #expect(String(data: decoded!, encoding: .utf8) == #"{"iss":"apple.com"}"#)
    }

    @Test("validateToken accepts an unexpired token with iss and exp claims")
    func validatesUnexpiredToken() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let exp = Int(nowMs / 1000) + 3_600 // +1 hour, in seconds (JWT convention)
        let token = Self.makeToken(payload: #"{"iss":"AMPWebPlay","exp":\#(exp)}"#)
        let discovered = AppleMusicCanvasProvider.validateToken(token, nowMs: nowMs)
        #expect(discovered?.token == token)
        #expect(discovered?.expiryMs == Int64(exp) * 1000)
    }

    @Test("validateToken rejects expired, iss-less, and malformed tokens")
    func rejectsInvalidTokens() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let nowSeconds = Int(nowMs / 1000)

        // Expired (exp in seconds).
        let expired = Self.makeToken(payload: #"{"iss":"AMPWebPlay","exp":\#(nowSeconds - 3_600)}"#)
        #expect(AppleMusicCanvasProvider.validateToken(expired, nowMs: nowMs) == nil)

        // Missing iss.
        let noIss = Self.makeToken(payload: #"{"exp":\#(nowSeconds + 3_600)}"#)
        #expect(AppleMusicCanvasProvider.validateToken(noIss, nowMs: nowMs) == nil)

        // Missing exp.
        let noExp = Self.makeToken(payload: #"{"iss":"AMPWebPlay"}"#)
        #expect(AppleMusicCanvasProvider.validateToken(noExp, nowMs: nowMs) == nil)

        // Not a JWT.
        #expect(AppleMusicCanvasProvider.validateToken("not-a-token", nowMs: nowMs) == nil)
        #expect(AppleMusicCanvasProvider.validateToken("a.b", nowMs: nowMs) == nil)
    }

    // MARK: - Helpers

    /// Builds a header.payload.signature JWT from a JSON payload string.
    private static func makeToken(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
