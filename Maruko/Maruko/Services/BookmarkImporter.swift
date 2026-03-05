import Foundation
import SwiftData
import SwiftSoup

struct ParsedBookmark: Sendable {
    let title: String
    let url: String
    let normalizedURL: String
    let group: String
}

struct ImportResult: Sendable {
    let importedCount: Int
    let skippedCount: Int
}

enum BookmarkImporterError: LocalizedError {
    case invalidHTML

    var errorDescription: String? {
        switch self {
        case .invalidHTML:
            return "The selected file could not be parsed as Netscape bookmark HTML."
        }
    }
}

struct BookmarkImporter {
    func `import`(from fileURL: URL, into context: ModelContext, rules: [GroupingRule]) async throws -> ImportResult {
        let parsed = try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            return try Self.parseBookmarks(from: fileURL)
        }.value

        let existing = try Deduplicator.existingNormalizedURLs(in: context)
        let unique = Deduplicator.uniqueCandidates(from: parsed, excluding: existing)

        for candidate in unique {
            let classification = BookmarkRuleEngine.classify(
                title: candidate.title,
                url: candidate.url,
                fallbackGroup: candidate.group,
                rules: rules
            )

            context.insert(
                Bookmark(
                    title: classification.title,
                    url: candidate.url,
                    normalizedURL: candidate.normalizedURL,
                    group: classification.group,
                    dateAdded: Date()
                )
            )
        }

        if !unique.isEmpty {
            try context.save()
        }

        return ImportResult(importedCount: unique.count, skippedCount: parsed.count - unique.count)
    }

    nonisolated private static func parseBookmarks(from fileURL: URL) throws -> [ParsedBookmark] {
        let data = try Data(contentsOf: fileURL)
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let document = try SwiftSoup.parse(html)

        guard let rootDL = try document.select("dl").first() else {
            throw BookmarkImporterError.invalidHTML
        }

        let links = try rootDL.select("a[href]")
        var output: [ParsedBookmark] = []
        output.reserveCapacity(links.count)

        for link in links {
            let href = try link.attr("href")
            guard let normalized = URLNormalizer.normalize(href) else {
                continue
            }

            let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? (URL(string: href)?.host ?? href) : title
            let group = try resolveGroup(for: link)

            output.append(
                ParsedBookmark(
                    title: resolvedTitle,
                    url: href,
                    normalizedURL: normalized,
                    group: group
                )
            )
        }

        return output
    }

    nonisolated private static func resolveGroup(for link: Element) throws -> String {
        var cursor: Element? = link

        while let current = cursor {
            if current.tagName().lowercased() == "dl",
               let headerContainer = try current.previousElementSibling(),
               headerContainer.tagName().lowercased() == "dt",
               let header = try headerContainer.select("h3").first() {
                let group = try header.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !group.isEmpty {
                    return group
                }
            }

            cursor = current.parent()
        }

        return "Ungrouped"
    }
}
