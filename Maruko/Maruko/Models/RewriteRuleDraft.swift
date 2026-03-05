import Foundation

struct RewriteRuleDraft {
    var name: String
    var isEnabled: Bool
    var order: Int
    var matchField: RewriteMatchField
    var pattern: String
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
    init(rule: RewriteRule) {
        self.name = rule.name
        self.isEnabled = rule.isEnabled
        self.order = rule.order
        self.matchField = rule.matchField
        self.pattern = rule.pattern
        self.replacementTemplate = rule.replacementTemplate
        self.isCaseSensitive = rule.isCaseSensitive
    }
}
