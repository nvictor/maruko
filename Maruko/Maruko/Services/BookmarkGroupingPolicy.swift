import Foundation

struct BookmarkClassification {
    let title: String
    let group: String
}

enum BookmarkGroupingPolicy {
    static func classify(title: String, url: String, fallbackGroup: String = "Ungrouped") -> BookmarkClassification {
        let normalizedTitle = normalizedTitleForCodeHosts(originalTitle: title, url: url)
        let lowercasedTitle = normalizedTitle.lowercased()

        if lowercasedTitle.contains("article") {
            return BookmarkClassification(title: normalizedTitle, group: "article")
        }
        if lowercasedTitle.contains("people") {
            return BookmarkClassification(title: normalizedTitle, group: "people")
        }
        if lowercasedTitle.contains("shopping") {
            return BookmarkClassification(title: normalizedTitle, group: "shopping")
        }
        if lowercasedTitle.contains("vst") {
            return BookmarkClassification(title: normalizedTitle, group: "vst")
        }

        let host = DomainExtractor.domain(from: url)
        let group = registrableDomain(fromHost: host) ?? fallbackGroup

        return BookmarkClassification(title: normalizedTitle, group: group)
    }

    private static func normalizedTitleForCodeHosts(originalTitle: String, url: String) -> String {
        guard let parsedURL = URL(string: url), let host = parsedURL.host?.lowercased() else {
            return originalTitle
        }

        let pathParts = parsedURL.path
            .split(separator: "/")
            .map(String.init)

        guard pathParts.count >= 2 else {
            return originalTitle
        }

        let owner = pathParts[0].lowercased()
        let repo = pathParts[1].lowercased()

        switch host {
        case "github.com":
            return "github \(owner)/\(repo)"
        case "gitlab.com":
            return "gitlab \(owner)/\(repo)"
        case "bitbucket.org":
            return "bitbucket \(owner)/\(repo)"
        default:
            return originalTitle
        }
    }

    private static func registrableDomain(fromHost host: String) -> String? {
        let sanitized = host
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty, sanitized != "unknown domain" else {
            return nil
        }

        let components = sanitized
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "www" }

        guard !components.isEmpty else {
            return nil
        }

        if components.count == 1 {
            return components[0]
        }

        if components.count >= 3 {
            let secondLevel = components[components.count - 2]
            let tld = components[components.count - 1]
            let commonSecondLevelDomains: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
            if tld.count == 2, commonSecondLevelDomains.contains(secondLevel) {
                return components[components.count - 3]
            }
        }

        return components[components.count - 2]
    }
}
