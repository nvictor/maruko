import Foundation
import SwiftData

enum Deduplicator {
    static func existingNormalizedURLs(in context: ModelContext) throws -> Set<String> {
        let descriptor = FetchDescriptor<Bookmark>()
        let existing = try context.fetch(descriptor)
        return Set(existing.map(\.normalizedURL))
    }

    static func uniqueCandidates(
        from parsedBookmarks: [ParsedBookmark],
        excluding existingURLs: Set<String>
    ) -> [ParsedBookmark] {
        var seen = existingURLs
        var unique: [ParsedBookmark] = []
        unique.reserveCapacity(parsedBookmarks.count)

        for bookmark in parsedBookmarks {
            if seen.insert(bookmark.normalizedURL).inserted {
                unique.append(bookmark)
            }
        }

        return unique
    }
}
