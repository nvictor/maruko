import Foundation

/// User-editable switches for what Maruko does when curating bookmarks.
/// Applies to every browser profile.
nonisolated struct FormatOptions: Codable, Equatable, Sendable {
    var removeDuplicates = true

    static let `default` = FormatOptions()

    /// How far back "most accessed" reaches, in days. Fixed, not user-editable.
    static let recencyWindowDays = 30
    /// Maximum number of direct URL children kept in "Routine".
    static let maxRoutineItems = 20
    /// Maximum number of direct URL children kept in "Recent".
    static let maxRecentItems = 20

    var recencyCutoff: Date {
        Date().addingTimeInterval(-Double(Self.recencyWindowDays) * 24 * 60 * 60)
    }

    private enum CodingKeys: String, CodingKey {
        case removeDuplicates
    }

    init(removeDuplicates: Bool = true) {
        self.removeDuplicates = removeDuplicates
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        removeDuplicates = try values.decodeIfPresent(Bool.self, forKey: .removeDuplicates) ?? true
    }
}
