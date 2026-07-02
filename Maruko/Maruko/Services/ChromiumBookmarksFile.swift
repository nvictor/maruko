import Foundation
import CryptoKit

enum ChromiumBookmarksFileError: LocalizedError {
    case notADictionary
    case missingRoots

    var errorDescription: String? {
        switch self {
        case .notADictionary:
            return "The Bookmarks file is not a JSON object."
        case .missingRoots:
            return "The Bookmarks file has no \"roots\" object."
        }
    }
}

/// Lossless reader/writer for Chromium's `Bookmarks` JSON file (Chrome, Brave,
/// Edge, Arc).
///
/// The file is kept as a raw `[String: Any]` dictionary rather than decoded
/// into typed structs: nodes carry keys that vary by browser and version
/// (`meta_info`, `date_last_used`, fork-specific extras) and the top level
/// carries a `sync_metadata` blob. Rebuilding dictionaries from typed models
/// would silently drop them; overwriting only the keys we mutate preserves
/// everything else byte-for-byte in value terms.
nonisolated struct ChromiumBookmarksFile {
    static let rootKeys = ["bookmark_bar", "other", "synced"]

    private(set) var root: [String: Any]

    static func load(from url: URL) throws -> ChromiumBookmarksFile {
        try load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> ChromiumBookmarksFile {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChromiumBookmarksFileError.notADictionary
        }
        guard object["roots"] is [String: Any] else {
            throw ChromiumBookmarksFileError.missingRoots
        }
        return ChromiumBookmarksFile(root: object)
    }

    var roots: [String: Any] {
        root["roots"] as? [String: Any] ?? [:]
    }

    func rootNode(_ key: String) -> [String: Any]? {
        roots[key] as? [String: Any]
    }

    mutating func replaceChildren(ofRoot key: String, with children: [[String: Any]]) {
        var roots = self.roots
        guard var node = roots[key] as? [String: Any] else { return }
        node["children"] = children
        roots[key] = node
        root["roots"] = roots
    }

    /// Serializes with a freshly computed checksum so Chromium loads the file
    /// without treating it as corrupt (an invalid checksum makes it reassign
    /// node ids, which churns sync).
    func serialized() throws -> Data {
        var output = root
        output["checksum"] = computeChecksum()
        return try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Chromium's bookmark checksum (see `BookmarkCodec`): MD5 over a DFS of
    /// the three standard roots in fixed order; per node the `id` (UTF-8), the
    /// `name` (UTF-16LE), then `"url"` + url for URL nodes or `"folder"` for
    /// folders.
    func computeChecksum() -> String {
        var md5 = Insecure.MD5()

        func update(utf8 value: String) {
            md5.update(data: Data(value.utf8))
        }

        func update(utf16 value: String) {
            if let data = value.data(using: .utf16LittleEndian) {
                md5.update(data: data)
            }
        }

        func walk(_ node: [String: Any]) {
            let id = node["id"] as? String ?? ""
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                update(utf8: id)
                update(utf16: name)
                update(utf8: "url")
                update(utf8: node["url"] as? String ?? "")
            } else {
                update(utf8: id)
                update(utf16: name)
                update(utf8: "folder")
                for child in node["children"] as? [[String: Any]] ?? [] {
                    walk(child)
                }
            }
        }

        for key in Self.rootKeys {
            if let node = rootNode(key) {
                walk(node)
            }
        }

        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
