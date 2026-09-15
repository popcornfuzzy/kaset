import Foundation

// MARK: - CastHTTPRequest

/// A parsed HTTP request line.
struct CastHTTPRequest: Equatable, Sendable {
    /// Request method, uppercased, e.g. `GET`.
    let method: String

    /// Request target, e.g. `/kaset-cast.aac`.
    let path: String

    /// Byte sequence that terminates HTTP request headers.
    static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Largest request head the server will buffer before giving up.
    static let maximumHeadSize = 8 * 1024

    /// Parses the start line of an HTTP request.
    ///
    /// Returns `nil` when the data does not yet contain a readable request line.
    static func parse(_ data: Data) -> CastHTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let line = text.components(separatedBy: "\r\n").first, !line.isEmpty else { return nil }

        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target

        return CastHTTPRequest(method: method, path: path)
    }

    /// Whether the buffered bytes contain a complete request head.
    static func containsCompleteHead(_ data: Data) -> Bool {
        data.range(of: Self.headerTerminator) != nil
    }
}

// MARK: - CastChunkedTransfer

/// Encodes audio bytes for `Transfer-Encoding: chunked` streaming.
enum CastChunkedTransfer {
    /// Terminating chunk that ends a chunked response body.
    static let terminator = Data("0\r\n\r\n".utf8)

    /// Wraps a payload in a single HTTP chunk.
    static func encode(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }
}

// MARK: - CastHTTPResponse

/// Builds HTTP responses for the local audio stream.
enum CastHTTPResponse {
    /// Response for an unknown path.
    static func notFound() -> Data {
        let body = Data("Not found".utf8)
        return self.response(
            status: "404 Not Found",
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
                "Connection": "close",
            ],
            body: body
        )
    }

    /// Response to a `HEAD` request, which advertises the stream without starting it.
    static func head(contentType: String) -> Data {
        self.response(
            status: "200 OK",
            headers: [
                "Content-Type": contentType,
                "Cache-Control": "no-cache",
                "Connection": "close",
            ],
            body: Data()
        )
    }

    /// Response for an unroutable request, e.g. a malformed request line.
    static func badRequest() -> Data {
        let body = Data("Bad request".utf8)
        return self.response(
            status: "400 Bad Request",
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
                "Connection": "close",
            ],
            body: body
        )
    }

    /// Response headers for an endless chunked audio stream.
    static func stream(contentType: String) -> Data {
        self.response(
            status: "200 OK",
            headers: [
                "Content-Type": contentType,
                "Cache-Control": "no-cache",
                "Transfer-Encoding": "chunked",
            ],
            body: Data()
        )
    }

    /// Assembles a response from a status line, headers, and body.
    ///
    /// Header names are written in sorted order so responses are byte-for-byte predictable.
    static func response(status: String, headers: [String: String], body: Data) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        for name in headers.keys.sorted() {
            text += "\(name): \(headers[name] ?? "")\r\n"
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
