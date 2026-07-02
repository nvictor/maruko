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

enum BookmarkRewriteEngine {
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    nonisolated private static let regexCacheLock = NSLock()

    static func sortedRules(_ rules: [RewriteRule]) -> [RewriteRule] {
        rules.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func rewrite(title: String, url: String, rules: [RewriteRule]) -> String {
        rewrite(title: title, url: url, snapshots: rules.map(\.snapshot))
    }

    nonisolated static func sortedSnapshots(_ rules: [RewriteRuleSnapshot]) -> [RewriteRuleSnapshot] {
        rules.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    nonisolated static func rewrite(title: String, url: String, snapshots: [RewriteRuleSnapshot]) -> String {
        var rewrittenTitle = title

        for rule in sortedSnapshots(snapshots) where rule.isEnabled {
            if let rewritten = apply(rule: rule, currentTitle: rewrittenTitle, url: url) {
                rewrittenTitle = rewritten
            }
        }

        return rewrittenTitle
    }

    static func validate(rule: RewriteRule) -> RewriteValidationResult {
        validate(snapshot: rule.snapshot, name: rule.name)
    }

    nonisolated static func validate(snapshot: RewriteRuleSnapshot, name: String) -> RewriteValidationResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = snapshot.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = snapshot.replacementTemplate.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            return .invalid(message: "Rule name cannot be empty.")
        }
        if pattern.isEmpty {
            return .invalid(message: "Pattern cannot be empty.")
        }
        if replacement.isEmpty {
            return .invalid(message: "Replacement cannot be empty.")
        }

        do {
            _ = try regex(for: pattern, caseSensitive: snapshot.isCaseSensitive)
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

    nonisolated private static func apply(rule: RewriteRuleSnapshot, currentTitle: String, url: String) -> String? {
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

    nonisolated private static func fieldsToSearch(_ field: RewriteMatchField, title: String, url: String) -> [String] {
        switch field {
        case .title:
            return [title]
        case .url:
            return [url]
        case .titleOrURL:
            return [title, url]
        }
    }

    nonisolated private static func regex(for pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
        let key = "\(caseSensitive ? "1" : "0"):\(pattern)"

        regexCacheLock.lock()
        let cached = regexCache[key]
        regexCacheLock.unlock()
        if let cached {
            return cached
        }

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let compiled = try NSRegularExpression(pattern: pattern, options: options)

        regexCacheLock.lock()
        regexCache[key] = compiled
        regexCacheLock.unlock()
        return compiled
    }

    nonisolated private static func rewriteAllMatches(in input: String, expression: NSRegularExpression, template: String) -> String {
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

    nonisolated private static func replacement(
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

    nonisolated private static func titleCase(_ text: String) -> String {
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
