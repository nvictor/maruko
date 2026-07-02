import Foundation

/// In-memory tree projection of one Chromium bookmark root. Not a SwiftData
/// model: it exists only between reading a `Bookmarks` file and writing it
/// back. Each node keeps its original raw dictionary so serialization
/// preserves every key the browser stored (guid, dates, meta_info, …).
nonisolated final class BookmarkNode {
    enum Kind {
        case folder
        case url
    }

    let kind: Kind
    var title: String
    let url: String?
    let normalizedURL: String?
    var children: [BookmarkNode]
    let raw: [String: Any]

    init?(raw: [String: Any]) {
        guard let type = raw["type"] as? String else { return nil }
        self.raw = raw
        self.title = raw["name"] as? String ?? ""

        switch type {
        case "url":
            kind = .url
            let urlString = raw["url"] as? String ?? ""
            url = urlString
            normalizedURL = URLNormalizer.normalize(urlString)
            children = []
        case "folder":
            kind = .folder
            url = nil
            normalizedURL = nil
            children = (raw["children"] as? [[String: Any]] ?? []).compactMap(BookmarkNode.init(raw:))
        default:
            return nil
        }
    }

    /// The original dictionary with only the mutable parts (title, children)
    /// overwritten — unknown keys pass through untouched.
    func dictionaryRepresentation() -> [String: Any] {
        var output = raw
        output["name"] = title
        if kind == .folder {
            output["children"] = children.map { $0.dictionaryRepresentation() }
        }
        return output
    }
}
