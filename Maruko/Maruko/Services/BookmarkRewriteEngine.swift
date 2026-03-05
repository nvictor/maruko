import Foundation

struct RewriteValidationIssue: Identifiable {
    let id: UUID
    let ruleName: String
    let message: String
}

enum RewriteValidationResult {
    case valid
    case invalid(message: String)
}

struct RewritePreview {
    let changedCount: Int
    let unchangedCount: Int
}

enum BookmarkRewriteEngine {
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    static func sortedRules(_ rules: [RewriteRule]) -> [RewriteRule] {
        rules.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func rewrite(title: String, url: String, rules: [RewriteRule]) -> String {
        var rewrittenTitle = title

        for rule in sortedRules(rules) where rule.isEnabled {
            if let rewritten = apply(rule: rule, currentTitle: rewrittenTitle, url: url) {
                rewrittenTitle = rewritten
            }
        }

        return rewrittenTitle
    }

    static func validate(rule: RewriteRule) -> RewriteValidationResult {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = rule.replacementTemplate.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            return .invalid(message: "Rule name cannot be empty.")
        }
        if pattern.isEmpty {
            return .invalid(message: "Pattern cannot be empty.")
        }
        if replacement.isEmpty {
            return .invalid(message: "Replacement cannot be empty.")
        }

        do {
            _ = try regex(for: pattern, caseSensitive: rule.isCaseSensitive)
        } catch {
            return .invalid(message: "Invalid regex: \(error.localizedDescription)")
        }

        return .valid
    }

    static func validate(rules: [RewriteRule]) -> [RewriteValidationIssue] {
        rules
            .filter(\.isEnabled)
            .compactMap { rule in
                switch validate(rule: rule) {
                case .valid:
                    return nil
                case .invalid(let message):
                    return RewriteValidationIssue(id: rule.id, ruleName: rule.name, message: message)
                }
            }
    }

    static func previewImpact(bookmarks: [Bookmark], rules: [RewriteRule]) -> RewritePreview {
        var changed = 0

        for bookmark in bookmarks {
            let rewritten = rewrite(title: bookmark.title, url: bookmark.url, rules: rules)
            if rewritten != bookmark.title {
                changed += 1
            }
        }

        return RewritePreview(changedCount: changed, unchangedCount: bookmarks.count - changed)
    }

    static func makeDefaultRules() -> [RewriteRule] {
        [
            RewriteRule(
                name: "GitHub Repo Title",
                isEnabled: true,
                order: 0,
                matchField: .url,
                pattern: #"^https://github\.com/([^/]+)/([^/?#]+)$"#,
                replacementTemplate: "github > $1 > $2",
                isCaseSensitive: false
            ),
            RewriteRule(
                name: "Article Title Prefix",
                isEnabled: true,
                order: 1,
                matchField: .title,
                pattern: #"(?i)^article\s+(.+)$"#,
                replacementTemplate: "Article ${titlecase:1}",
                isCaseSensitive: false
            )
        ]
    }

    private static func apply(rule: RewriteRule, currentTitle: String, url: String) -> String? {
        guard let expression = try? regex(for: rule.pattern, caseSensitive: rule.isCaseSensitive) else {
            return nil
        }

        for input in fieldsToSearch(rule.matchField, title: currentTitle, url: url) {
            let rewritten = rewriteAllMatches(
                in: input,
                expression: expression,
                template: rule.replacementTemplate
            )
            if rewritten != input {
                return rewritten
            }
        }

        return nil
    }

    private static func fieldsToSearch(_ field: RewriteMatchField, title: String, url: String) -> [String] {
        switch field {
        case .title:
            return [title]
        case .url:
            return [url]
        case .titleOrURL:
            return [title, url]
        }
    }

    private static func regex(for pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
        let key = "\(caseSensitive ? "1" : "0"):\(pattern)"
        if let cached = regexCache[key] {
            return cached
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let compiled = try NSRegularExpression(pattern: pattern, options: options)
        regexCache[key] = compiled
        return compiled
    }

    private static func rewriteAllMatches(in input: String, expression: NSRegularExpression, template: String) -> String {
        let fullRange = NSRange(input.startIndex..., in: input)
        let matches = expression.matches(in: input, options: [], range: fullRange)
        guard !matches.isEmpty else { return input }

        let source = input as NSString
        var output = ""
        var cursor = 0

        for match in matches {
            let matchRange = match.range
            let prefixRange = NSRange(location: cursor, length: matchRange.location - cursor)
            output += source.substring(with: prefixRange)
            output += replacement(for: match, in: input, expression: expression, template: template)
            cursor = matchRange.location + matchRange.length
        }

        let suffixRange = NSRange(location: cursor, length: source.length - cursor)
        output += source.substring(with: suffixRange)
        return output
    }

    private static func replacement(
        for match: NSTextCheckingResult,
        in input: String,
        expression: NSRegularExpression,
        template: String
    ) -> String {
        let markerRegex = try? NSRegularExpression(pattern: #"\$\{titlecase:(\d+)\}"#)
        guard let markerRegex else {
            return expression.replacementString(for: match, in: input, offset: 0, template: template)
        }

        let nsTemplate = template as NSString
        let templateRange = NSRange(location: 0, length: nsTemplate.length)
        let markerMatches = markerRegex.matches(in: template, options: [], range: templateRange)

        guard !markerMatches.isEmpty else {
            return expression.replacementString(for: match, in: input, offset: 0, template: template)
        }

        var transformedTemplate = template
        var replacements: [String: String] = [:]

        for (index, marker) in markerMatches.enumerated().reversed() {
            guard marker.numberOfRanges >= 2,
                  let groupRange = Range(marker.range(at: 1), in: template),
                  let markerRange = Range(marker.range(at: 0), in: template),
                  let groupIndex = Int(template[groupRange]) else {
                continue
            }

            let captured: String
            if groupIndex < match.numberOfRanges,
               let captureRange = Range(match.range(at: groupIndex), in: input) {
                captured = String(input[captureRange])
            } else {
                captured = ""
            }

            let placeholder = "__TC_\(index)__"
            replacements[placeholder] = titleCase(captured)
            transformedTemplate.replaceSubrange(markerRange, with: placeholder)
        }

        var replaced = expression.replacementString(
            for: match,
            in: input,
            offset: 0,
            template: transformedTemplate
        )

        for (placeholder, value) in replacements {
            replaced = replaced.replacingOccurrences(of: placeholder, with: value)
        }

        return replaced
    }

    private static func titleCase(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                let lower = token.lowercased()
                guard let first = lower.first else { return "" }
                return String(first).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
