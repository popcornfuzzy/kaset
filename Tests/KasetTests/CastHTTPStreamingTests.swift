import Foundation
import Testing
@testable import Kaset

/// The local HTTP stream the Cast receiver fetches.
@Suite(.tags(.service))
struct CastHTTPStreamingTests {
    // MARK: - Request Parsing

    @Test("Parses a GET request")
    func parsesGetRequest() throws {
        let data = Data("GET /kaset-cast.aac HTTP/1.1\r\nHost: 192.168.1.10\r\n\r\n".utf8)

        let request = try #require(CastHTTPRequest.parse(data))
        #expect(request.method == "GET")
        #expect(request.path == "/kaset-cast.aac")
    }

    @Test("Parses a HEAD request and strips the query string")
    func parsesHeadRequestWithoutQuery() throws {
        let data = Data("HEAD /kaset-cast.aac?token=1 HTTP/1.1\r\n\r\n".utf8)

        let request = try #require(CastHTTPRequest.parse(data))
        #expect(request.method == "HEAD")
        #expect(request.path == "/kaset-cast.aac")
    }

    @Test("Uppercases the request method")
    func uppercasesMethod() throws {
        let request = try #require(CastHTTPRequest.parse(Data("get /stream HTTP/1.1\r\n\r\n".utf8)))
        #expect(request.method == "GET")
    }

    @Test("Refuses to parse an incomplete request line")
    func refusesIncompleteRequest() {
        #expect(CastHTTPRequest.parse(Data()) == nil)
        #expect(CastHTTPRequest.parse(Data("GET".utf8)) == nil)
        #expect(CastHTTPRequest.parse(Data("\r\n".utf8)) == nil)
    }

    @Test("Detects a complete request head")
    func detectsCompleteHead() {
        #expect(CastHTTPRequest.containsCompleteHead(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        #expect(!CastHTTPRequest.containsCompleteHead(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
    }

    // MARK: - Chunked Transfer

    @Test("Wraps payloads in HTTP chunks")
    func wrapsPayloadInChunk() {
        let chunk = CastChunkedTransfer.encode(Data("hello".utf8))

        #expect(String(decoding: chunk, as: UTF8.self) == "5\r\nhello\r\n")
    }

    @Test("Encodes chunk sizes in hexadecimal")
    func encodesChunkSizeInHex() {
        let chunk = CastChunkedTransfer.encode(Data(repeating: 0x41, count: 16))
        #expect(String(decoding: chunk.prefix(3), as: UTF8.self) == "10\r")
    }

    @Test("Encoding an empty payload produces no chunk")
    func encodesEmptyPayloadAsNothing() {
        #expect(CastChunkedTransfer.encode(Data()).isEmpty)
    }

    @Test("Terminator ends the chunked body")
    func terminatorMatchesHTTP() {
        #expect(String(decoding: CastChunkedTransfer.terminator, as: UTF8.self) == "0\r\n\r\n")
    }

    // MARK: - Responses

    @Test("Stream response advertises a chunked audio stream")
    func streamResponseHeaders() {
        let response = String(decoding: CastHTTPResponse.stream(contentType: "audio/aac"), as: UTF8.self)

        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Type: audio/aac\r\n"))
        #expect(response.contains("Transfer-Encoding: chunked\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test("HEAD response has headers but no body")
    func headResponseHasNoBody() {
        let data = CastHTTPResponse.head(contentType: "audio/aac")
        let response = String(decoding: data, as: UTF8.self)

        #expect(response.contains("Content-Type: audio/aac\r\n"))
        #expect(response.contains("Connection: close\r\n"))
        #expect(!response.contains("Transfer-Encoding"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test("Not found response reports a length and closes the connection")
    func notFoundResponse() {
        let response = String(decoding: CastHTTPResponse.notFound(), as: UTF8.self)

        #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(response.contains("Content-Length: 9\r\n"))
        #expect(response.hasSuffix("\r\n\r\nNot found"))
    }

    @Test("Bad request response closes the connection")
    func badRequestResponse() {
        let response = String(decoding: CastHTTPResponse.badRequest(), as: UTF8.self)

        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(response.hasSuffix("Bad request"))
    }

    @Test("Header order is deterministic")
    func headerOrderIsDeterministic() {
        let first = CastHTTPResponse.response(
            status: "200 OK",
            headers: ["B": "2", "A": "1", "C": "3"],
            body: Data()
        )
        let second = CastHTTPResponse.response(
            status: "200 OK",
            headers: ["C": "3", "B": "2", "A": "1"],
            body: Data()
        )

        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self) == "HTTP/1.1 200 OK\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n")
    }

    @Test("Response appends the body after the header block")
    func responseAppendsBody() {
        let data = CastHTTPResponse.response(status: "200 OK", headers: [:], body: Data("body".utf8))

        #expect(String(decoding: data, as: UTF8.self) == "HTTP/1.1 200 OK\r\n\r\nbody")
    }
}
