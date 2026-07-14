import Foundation

nonisolated struct WebpageTitleCandidate: Equatable, Sendable {
    let nodeID: String
    let url: String
}

/// Fetches current HTML document titles without involving a language model.
/// Loading is injectable so parsing and failure behavior can be tested without
/// making network requests.
nonisolated struct WebpageTitleRefresher: Sendable {
    typealias Loader = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)

    static let maximumResponseBytes = 512 * 1024
    static let maximumTitleLength = 500

    var maximumConcurrentRequests = 4
    var requestTimeout: TimeInterval = 10
    private let load: Loader

    init(load: @escaping Loader = WebpageTitleRefresher.loadFromNetwork) {
        self.load = load
    }

    func refresh(
        candidates: [WebpageTitleCandidate],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [String: String] {
        guard !candidates.isEmpty else { return [:] }
        let total = candidates.count
        var completed = 0
        var titles: [String: String] = [:]

        for start in stride(from: 0, to: total, by: max(1, maximumConcurrentRequests)) {
            try Task.checkCancellation()
            let end = min(start + max(1, maximumConcurrentRequests), total)
            let batch = candidates[start..<end]
            let results = await withTaskGroup(of: (String, String?).self) { group in
                for candidate in batch {
                    group.addTask {
                        let title = try? await title(for: candidate.url)
                        return (candidate.nodeID, title)
                    }
                }
                var values: [(String, String?)] = []
                for await result in group { values.append(result) }
                return values
            }
            try Task.checkCancellation()
            for (nodeID, title) in results {
                if let title { titles[nodeID] = title }
                completed += 1
                progress(completed, total)
            }
        }
        return titles
    }

    private func title(for urlString: String) async throws -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Maruko/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request, Self.maximumResponseBytes)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              Self.isHTML(http.mimeType),
              data.count <= Self.maximumResponseBytes,
              let html = Self.decode(data, response: http),
              let rawTitle = Self.firstTitle(in: html) else { return nil }

        let title = Self.decodeEntities(rawTitle)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.maximumTitleLength else { return nil }
        return title
    }

    private static func loadFromNetwork(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { break }
            data.append(byte)
        }
        return (data, response)
    }

    private static func isHTML(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType == "text/html" || mimeType == "application/xhtml+xml"
    }

    private static func decode(_ data: Data, response: HTTPURLResponse) -> String? {
        if let charset = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let decoded = String(data: data, encoding: encoding) { return decoded }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func firstTitle(in html: String) -> String? {
        let expression = try? NSRegularExpression(
            pattern: #"<title(?:\s[^>]*)?>(.*?)</title\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        guard let expression,
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    private static func decodeEntities(_ input: String) -> String {
        var output = input
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        for (entity, value) in named {
            output = output.replacingOccurrences(of: "&\(entity);", with: value, options: .caseInsensitive)
        }
        guard let expression = try? NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: .caseInsensitive) else {
            return output
        }
        let matches = expression.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed()
        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 1), in: output) else { continue }
            let token = String(output[valueRange])
            let number = token.lowercased().hasPrefix("x")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token, radix: 10)
            if let number, let scalar = UnicodeScalar(number) {
                output.replaceSubrange(wholeRange, with: String(Character(scalar)))
            }
        }
        return output
    }
}
