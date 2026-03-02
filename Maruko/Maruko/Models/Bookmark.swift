import Foundation
import SwiftData

@Model
final class Bookmark {
    var title: String
    var url: String
    @Attribute(.unique) var normalizedURL: String
    var group: String
    var dateAdded: Date

    init(
        title: String,
        url: String,
        normalizedURL: String,
        group: String,
        dateAdded: Date = Date()
    ) {
        self.title = title
        self.url = url
        self.normalizedURL = normalizedURL
        self.group = group
        self.dateAdded = dateAdded
    }
}
