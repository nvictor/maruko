import Foundation
import SwiftData

enum RuleKind: String, CaseIterable, Codable {
    case regex
    case containsText
    case domain
}

enum MatchField: String, CaseIterable, Codable {
    case title
    case url
    case titleOrURL
}

@Model
final class GroupingRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var isEnabled: Bool
    var order: Int
    var kindRaw: String
    var matchFieldRaw: String
    var pattern: String
    var targetGroup: String
    var isCaseSensitive: Bool
    var createdAt: Date
    var updatedAt: Date

    var kind: RuleKind {
        get { RuleKind(rawValue: kindRaw) ?? .containsText }
        set { kindRaw = newValue.rawValue }
    }

    var matchField: MatchField {
        get { MatchField(rawValue: matchFieldRaw) ?? .titleOrURL }
        set { matchFieldRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        order: Int,
        kind: RuleKind,
        pattern: String,
        targetGroup: String,
        matchField: MatchField = .titleOrURL,
        isCaseSensitive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.order = order
        self.kindRaw = kind.rawValue
        self.matchFieldRaw = matchField.rawValue
        self.pattern = pattern
        self.targetGroup = targetGroup
        self.isCaseSensitive = isCaseSensitive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
