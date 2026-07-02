import Foundation

/// Minimal HTTP/1.1 message handling for the localhost extension server.
/// Pure and socketless so it can be tested without networking: the server
/// feeds received bytes into `HTTPRequestParser` and writes back
/// `HTTPResponse.serialized()`.

nonisolated struct HTTPRequest: Sendable {
    let method: String
    let path: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated enum HTTPParseError: LocalizedError, Equatable {
    case malformedRequestLine
    case lengthRequired
    case bodyTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedRequestLine: return "Malformed HTTP request line."
        case .lengthRequired: return "Content-Length is required."
        case .bodyTooLarge: return "Request body exceeds the size limit."
        }
    }

    /// The status the server should answer with before closing.
    var statusCode: Int {
        switch self {
        case .malformedRequestLine: return 400
        case .lengthRequired: return 411
        case .bodyTooLarge: return 413
        }
    }
}

/// Incremental request parser: call `append` with each received chunk; it
/// returns the request once the head and full body have arrived, or throws
/// an `HTTPParseError`. One parser handles one request (connections are
/// `Connection: close`).
nonisolated struct HTTPRequestParser {
    static let maxBodyBytes = 64 * 1024 * 1024

    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String], bodyLength: Int)?

    mutating func append(_ data: Data) throws -> HTTPRequest? {
        buffer.append(data)

        if head == nil {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                // Guard against an endless header section.
                if buffer.count > 1024 * 1024 { throw HTTPParseError.malformedRequestLine }
                return nil
            }
            let headData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
            head = try Self.parseHead(headData)
        }

        guard let head else { return nil }
        guard buffer.count >= head.bodyLength else { return nil }

        let body = buffer.prefix(head.bodyLength)
        return HTTPRequest(
            method: head.method,
            path: head.path,
            headers: head.headers,
            body: Data(body)
        )
    }

    private static func parseHead(
        _ data: Data
    ) throws -> (method: String, path: String, headers: [String: String], bodyLength: Int) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPParseError.malformedRequestLine
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestParts = lines[0].split(separator: " ")
        guard requestParts.count == 3 else {
            throw HTTPParseError.malformedRequestLine
        }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var bodyLength = 0
        if let lengthValue = headers["content-length"] {
            guard let length = Int(lengthValue), length >= 0 else {
                throw HTTPParseError.malformedRequestLine
            }
            guard length <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
            bodyLength = length
        } else if method == "POST" || method == "PUT" {
            throw HTTPParseError.lengthRequired
        }

        return (method, path, headers, bodyLength)
    }
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType: String

    static func json(_ status: Int, _ object: some Encodable) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body, contentType: "application/json")
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        struct ErrorBody: Encodable { let error: String }
        return json(status, ErrorBody(error: message))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}
