import Foundation

struct RuleValidationIssue: Identifiable {
    let id: UUID
    let ruleName: String
    let pattern: String
    let message: String
}

enum RuleValidationResult {
    case valid
    case invalid(message: String)
}

struct RuleApplyPreview {
    let changedCount: Int
    let unchangedCount: Int
}

enum BookmarkRuleEngine {
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    static func sortedRules(_ rules: [GroupingRule]) -> [GroupingRule] {
        rules.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func classify(
        title: String,
        url: String,
        fallbackGroup: String = "Ungrouped",
        rules: [GroupingRule]
    ) -> BookmarkClassification {
        for rule in sortedRules(rules) where rule.isEnabled {
            if matches(rule: rule, title: title, url: url) {
                let group = normalizedGroupName(rule.targetGroup)
                return BookmarkClassification(title: title, group: group)
            }
        }

        let host = DomainExtractor.domain(from: url)
        let fallback = registrableDomain(fromHost: host) ?? normalizedGroupName(fallbackGroup)
        return BookmarkClassification(title: title, group: fallback)
    }

    static func validate(rule: GroupingRule) -> RuleValidationResult {
        let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = rule.targetGroup.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPattern.isEmpty {
            return .invalid(message: "Pattern cannot be empty.")
        }
        if trimmedTarget.isEmpty {
            return .invalid(message: "Target group cannot be empty.")
        }

        guard rule.kind == .regex else {
            return .valid
        }

        do {
            _ = try regex(for: trimmedPattern, isCaseSensitive: rule.isCaseSensitive)
            return .valid
        } catch {
            return .invalid(message: "Invalid regex: \(error.localizedDescription)")
        }
    }

    static func validate(rules: [GroupingRule]) -> [RuleValidationIssue] {
        rules
            .filter(\.isEnabled)
            .compactMap { rule in
                switch validate(rule: rule) {
                case .valid:
                    return nil
                case .invalid(let message):
                    return RuleValidationIssue(
                        id: rule.id,
                        ruleName: rule.name,
                        pattern: rule.pattern,
                        message: message
                    )
                }
            }
    }

    static func previewImpact(
        bookmarks: [Bookmark],
        rules: [GroupingRule],
        fallbackEnabled: Bool = true
    ) -> RuleApplyPreview {
        var changedCount = 0

        for bookmark in bookmarks {
            let classification = classify(
                title: bookmark.title,
                url: bookmark.url,
                fallbackGroup: fallbackEnabled ? normalizedGroupName(bookmark.group) : "Ungrouped",
                rules: rules
            )

            if bookmark.title != classification.title || bookmark.group != classification.group {
                changedCount += 1
            }
        }

        return RuleApplyPreview(changedCount: changedCount, unchangedCount: bookmarks.count - changedCount)
    }

    static func makeDefaultRules() -> [GroupingRule] {
        let defaults: [(name: String, pattern: String, target: String)] = [
            ("Article", "article", "article"),
            ("People", "people", "people"),
            ("Shopping", "shopping", "shopping"),
            ("VST", "vst", "vst")
        ]

        return defaults.enumerated().map { index, item in
            GroupingRule(
                name: item.name,
                isEnabled: true,
                order: index,
                kind: .containsText,
                pattern: item.pattern,
                targetGroup: item.target,
                matchField: .title,
                isCaseSensitive: false
            )
        }
    }

    private static func matches(rule: GroupingRule, title: String, url: String) -> Bool {
        let fields = fieldsToSearch(rule.matchField, title: title, url: url)

        switch rule.kind {
        case .containsText:
            return fields.contains { field in
                contains(field, pattern: rule.pattern, caseSensitive: rule.isCaseSensitive)
            }
        case .regex:
            return fields.contains { field in
                regexMatches(field, pattern: rule.pattern, caseSensitive: rule.isCaseSensitive)
            }
        case .domain:
            guard let host = URL(string: url)?.host?.lowercased() else { return false }
            let needle = rule.isCaseSensitive ? rule.pattern : rule.pattern.lowercased()
            let haystack = rule.isCaseSensitive ? host : host.lowercased()
            return haystack.contains(needle)
        }
    }

    private static func fieldsToSearch(_ field: MatchField, title: String, url: String) -> [String] {
        switch field {
        case .title:
            return [title]
        case .url:
            return [url]
        case .titleOrURL:
            return [title, url]
        }
    }

    private static func contains(_ text: String, pattern: String, caseSensitive: Bool) -> Bool {
        if caseSensitive {
            return text.contains(pattern)
        }
        return text.localizedCaseInsensitiveContains(pattern)
    }

    private static func regexMatches(_ text: String, pattern: String, caseSensitive: Bool) -> Bool {
        do {
            let expression = try regex(for: pattern, isCaseSensitive: caseSensitive)
            let range = NSRange(text.startIndex..., in: text)
            return expression.firstMatch(in: text, range: range) != nil
        } catch {
            return false
        }
    }

    private static func regex(for pattern: String, isCaseSensitive: Bool) throws -> NSRegularExpression {
        let key = "\(isCaseSensitive ? "1" : "0"):\(pattern)"

        if let cached = regexCache[key] {
            return cached
        }

        let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
        let created = try NSRegularExpression(pattern: pattern, options: options)
        regexCache[key] = created
        return created
    }

    private static func registrableDomain(fromHost host: String) -> String? {
        let sanitized = host
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty, sanitized != "unknown domain" else {
            return nil
        }

        let components = sanitized
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "www" }

        guard !components.isEmpty else {
            return nil
        }

        if components.count == 1 {
            return components[0]
        }

        if components.count >= 3 {
            let secondLevel = components[components.count - 2]
            let tld = components[components.count - 1]
            let commonSecondLevelDomains: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
            if tld.count == 2, commonSecondLevelDomains.contains(secondLevel) {
                return components[components.count - 3]
            }
        }

        return components[components.count - 2]
    }

    private static func normalizedGroupName(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ungrouped" : trimmed
    }
}
