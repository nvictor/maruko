import Foundation

enum DomainExtractor {
    static func domain(from urlString: String) -> String {
        guard let components = URLComponents(string: urlString),
              let host = components.host,
              !host.isEmpty else {
            return "Unknown Domain"
        }

        return host.lowercased()
    }
}
