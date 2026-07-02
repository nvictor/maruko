import Foundation

/// User-editable switches for what "Format Bookmarks" does. Applies to every
/// browser profile.
nonisolated struct FormatOptions: Codable, Equatable, Sendable {
    var removeDuplicates = true
    var rewriteTitles = true
    /// Move bookmarks opened within `recencyWindowDays` to the top of their
    /// folder. Never reorders the bookmark bar's own row of items.
    var moveRecentToTop = true
    var recencyWindowDays = 30

    static let `default` = FormatOptions()
    static let recencyWindowChoices = [7, 30, 90]

    var recencyCutoff: Date {
        Date().addingTimeInterval(-Double(recencyWindowDays) * 24 * 60 * 60)
    }
}
