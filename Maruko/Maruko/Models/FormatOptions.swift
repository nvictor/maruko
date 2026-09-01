import Foundation

/// User-editable switches for what "Format Bookmarks" does. Applies to every
/// browser profile.
nonisolated struct FormatOptions: Codable, Equatable, Sendable {
    var removeDuplicates = true
    var rewriteTitles = true
    var refreshTitlesFromWebpages = false
    /// Move bookmarks opened within the last `recencyWindowDays` days to the top
    /// of their folder. Never reorders the bookmark bar's own row of items.
    var moveRecentToTop = true

    static let `default` = FormatOptions()

    /// How far back "recently opened" reaches, in days. Fixed, not user-editable.
    static let recencyWindowDays = 7

    var recencyCutoff: Date {
        Date().addingTimeInterval(-Double(Self.recencyWindowDays) * 24 * 60 * 60)
    }

    private enum CodingKeys: String, CodingKey {
        case removeDuplicates, rewriteTitles, refreshTitlesFromWebpages
        case moveRecentToTop
    }

    init(
        removeDuplicates: Bool = true,
        rewriteTitles: Bool = true,
        refreshTitlesFromWebpages: Bool = false,
        moveRecentToTop: Bool = true
    ) {
        self.removeDuplicates = removeDuplicates
        self.rewriteTitles = rewriteTitles
        self.refreshTitlesFromWebpages = refreshTitlesFromWebpages
        self.moveRecentToTop = moveRecentToTop
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        removeDuplicates = try values.decodeIfPresent(Bool.self, forKey: .removeDuplicates) ?? true
        rewriteTitles = try values.decodeIfPresent(Bool.self, forKey: .rewriteTitles) ?? true
        refreshTitlesFromWebpages = try values.decodeIfPresent(Bool.self, forKey: .refreshTitlesFromWebpages) ?? false
        moveRecentToTop = try values.decodeIfPresent(Bool.self, forKey: .moveRecentToTop) ?? true
    }
}
