import Foundation
import SwiftData

@Model
final class GroupState {
    @Attribute(.unique) var name: String
    var isHidden: Bool
    var hiddenBookmarkCount: Int
    var lastSeenBookmarkCount: Int
    var updatedAt: Date

    init(
        name: String,
        isHidden: Bool = false,
        hiddenBookmarkCount: Int = 0,
        lastSeenBookmarkCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.isHidden = isHidden
        self.hiddenBookmarkCount = hiddenBookmarkCount
        self.lastSeenBookmarkCount = lastSeenBookmarkCount
        self.updatedAt = updatedAt
    }
}
