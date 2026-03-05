import Foundation
import SwiftData

enum RewriteMatchField: String, CaseIterable, Codable {
    case title
    case url
    case titleOrURL
}

@Model
final class RewriteRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var isEnabled: Bool
    var order: Int
    var kindRaw: String
    var matchFieldRaw: String
    var pattern: String
    var replacementTemplate: String
    var isCaseSensitive: Bool
    var createdAt: Date
    var updatedAt: Date

    var matchField: RewriteMatchField {
        get { RewriteMatchField(rawValue: matchFieldRaw) ?? .title }
        set { matchFieldRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        order: Int,
        matchField: RewriteMatchField,
        pattern: String,
        replacementTemplate: String,
        isCaseSensitive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.order = order
        self.kindRaw = "regexMatchReplace"
        self.matchFieldRaw = matchField.rawValue
        self.pattern = pattern
        self.replacementTemplate = replacementTemplate
        self.isCaseSensitive = isCaseSensitive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
