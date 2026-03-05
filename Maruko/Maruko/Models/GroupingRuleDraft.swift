import Foundation

struct GroupingRuleDraft {
    var name: String
    var isEnabled: Bool
    var order: Int
    var kind: RuleKind
    var pattern: String
    var targetGroup: String
    var matchField: MatchField
    var isCaseSensitive: Bool

    static let `default` = GroupingRuleDraft(
        name: "",
        isEnabled: true,
        order: 0,
        kind: .containsText,
        pattern: "",
        targetGroup: "Ungrouped",
        matchField: .title,
        isCaseSensitive: false
    )
}

extension GroupingRuleDraft {
    init(rule: GroupingRule) {
        self.name = rule.name
        self.isEnabled = rule.isEnabled
        self.order = rule.order
        self.kind = rule.kind
        self.pattern = rule.pattern
        self.targetGroup = rule.targetGroup
        self.matchField = rule.matchField
        self.isCaseSensitive = rule.isCaseSensitive
    }
}
