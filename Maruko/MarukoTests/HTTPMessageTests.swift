import Foundation
import Testing
@testable import Maruko

struct HTTPMessageTests {
    @Test func assemblesARequestSplitAcrossChunks() throws {
        var parser = HTTPRequestParser()
        let raw = "POST /session HTTP/1.1\r\nHost: 127.0.0.1:38765\r\nX-Maruko-Token: abc\r\nContent-Length: 11\r\n\r\nhello world"
        let bytes = Data(raw.utf8)

        var request: HTTPRequest?
        // Feed 7 bytes at a time to force reassembly across chunks.
        var offset = bytes.startIndex
        while offset < bytes.endIndex, request == nil {
            let end = bytes.index(offset, offsetBy: 7, limitedBy: bytes.endIndex) ?? bytes.endIndex
            request = try parser.append(bytes[offset..<end])
            offset = end
        }

        let parsed = try #require(request)
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/session")
        #expect(parsed.header("host") == "127.0.0.1:38765")
        #expect(parsed.header("X-Maruko-Token") == "abc")
        #expect(String(data: parsed.body, encoding: .utf8) == "hello world")
    }

    @Test func getWithoutContentLengthParses() throws {
        var parser = HTTPRequestParser()
        let request = try parser.append(Data("GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))

        #expect(request?.method == "GET")
        #expect(request?.body.isEmpty == true)
    }

    @Test func postWithoutContentLengthIsRejected() {
        var parser = HTTPRequestParser()

        #expect(throws: HTTPParseError.lengthRequired) {
            _ = try parser.append(Data("POST /session HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        }
    }

    @Test func oversizedBodyIsRejected() {
        var parser = HTTPRequestParser()
        let raw = "POST /session HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maxBodyBytes + 1)\r\n\r\n"

        #expect(throws: HTTPParseError.bodyTooLarge) {
            _ = try parser.append(Data(raw.utf8))
        }
    }

    @Test func responseSerializesWithHeadersAndBody() throws {
        struct Payload: Encodable { let ok = true }
        let data = HTTPResponse.json(200, Payload()).serialized()
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}
