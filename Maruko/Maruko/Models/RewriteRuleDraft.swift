import Foundation

struct RewriteRuleDraft {
    var name: String
    var isEnabled: Bool
    var order: Int
    var kind: RewriteRuleKind = .regexMatchReplace
    var matchField: RewriteMatchField
    var pattern: String
    /// For `.aiPrompt` rules this holds the natural-language instructions.
    var replacementTemplate: String
    var isCaseSensitive: Bool

    static let `default` = RewriteRuleDraft(
        name: "",
        isEnabled: true,
        order: 0,
        matchField: .title,
        pattern: "article",
        replacementTemplate: "Article $1",
        isCaseSensitive: false
    )
}

extension RewriteRuleDraft {
    /// A throwaway snapshot for validating the draft and running the live
    /// "Try it" preview through the real engine.
    func previewSnapshot() -> RewriteRuleSnapshot {
        RewriteRuleSnapshot(
            id: UUID(),
            name: name,
            isEnabled: true,
            order: order,
            kind: kind,
            matchField: matchField,
            pattern: pattern,
            replacementTemplate: replacementTemplate,
            isCaseSensitive: isCaseSensitive,
            createdAt: Date()
        )
    }

    init(rule: RewriteRule) {
        self.name = rule.name
        self.isEnabled = rule.isEnabled
        self.order = rule.order
        self.kind = rule.kind
        self.matchField = rule.matchField
        self.pattern = rule.pattern
        self.replacementTemplate = rule.replacementTemplate
        self.isCaseSensitive = rule.isCaseSensitive
    }
}
