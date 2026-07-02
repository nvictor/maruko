import Foundation
import SwiftData

enum RewriteMatchField: String, CaseIterable, Codable {
    case title
    case url
    case titleOrURL
}

nonisolated enum RewriteRuleKind: String, CaseIterable, Codable, Sendable {
    case regexMatchReplace
    case aiPrompt

    var displayName: String {
        switch self {
        case .regexMatchReplace: "Regex"
        case .aiPrompt: "AI (Apple Intelligence)"
        }
    }
}

/// Sendable value copy of a `RewriteRule`, taken on the main actor so the
/// rewrite engine can run off-main without touching SwiftData objects.
struct RewriteRuleSnapshot: Sendable {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let order: Int
    let kind: RewriteRuleKind
    let matchField: RewriteMatchField
    let pattern: String
    /// For `.aiPrompt` rules this holds the natural-language instructions.
    let replacementTemplate: String
    let isCaseSensitive: Bool
    let createdAt: Date
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

    var kind: RewriteRuleKind {
        get { RewriteRuleKind(rawValue: kindRaw) ?? .regexMatchReplace }
        set { kindRaw = newValue.rawValue }
    }

    var snapshot: RewriteRuleSnapshot {
        RewriteRuleSnapshot(
            id: id,
            name: name,
            isEnabled: isEnabled,
            order: order,
            kind: kind,
            matchField: matchField,
            pattern: pattern,
            replacementTemplate: replacementTemplate,
            isCaseSensitive: isCaseSensitive,
            createdAt: createdAt
        )
    }

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        order: Int,
        kind: RewriteRuleKind = .regexMatchReplace,
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
        self.kindRaw = kind.rawValue
        self.matchFieldRaw = matchField.rawValue
        self.pattern = pattern
        self.replacementTemplate = replacementTemplate
        self.isCaseSensitive = isCaseSensitive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
