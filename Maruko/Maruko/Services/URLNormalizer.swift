import Foundation

enum URLNormalizer {
    nonisolated static func normalize(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prepared: String
        if trimmed.contains("://") {
            prepared = trimmed
        } else {
            prepared = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: prepared) else { return nil }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if components.path.isEmpty {
            components.path = "/"
        }

        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        if let port = components.port,
           (components.scheme == "http" && port == 80) || (components.scheme == "https" && port == 443) {
            components.port = nil
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
        }

        components.fragment = nil

        return components.string
    }
}
