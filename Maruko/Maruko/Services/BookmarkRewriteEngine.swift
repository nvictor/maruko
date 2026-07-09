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
    nonisolated static let defaultArticleTitleRewritePrompt = """
        Only rewrite titles that clearly look like article or blog post titles.

        Skip if the title is only a domain, site name, product name, app name, repo name, profile name, documentation section, homepage, or navigation label.

        Skip if the title has fewer than 4 words, unless it contains a clear article headline phrase.

        For matching titles, rewrite using proper title casing, then add the prefix Article, followed by a colon and one space, before the rewritten title.

        Do not rewrite based on the URL alone. The title itself must look like an article headline.
        """

    nonisolated static let defaultWikipediaTitleRewritePrompt = """
        Only apply this rule to Wikipedia articles — pages on wikipedia.org or
        any subdomain of it, such as en.wikipedia.org. You can tell from the
        URL shown next to the title. Skip every bookmark whose URL is not on
        a Wikipedia domain — that covers everything else, including ordinary
        articles or blog posts, which a separate rule already handles.

        For a matching bookmark, rewrite the title using proper title casing,
        drop any trailing hyphen-Wikipedia suffix added by the original page
        title — for example, turn Albert Einstein - Wikipedia into Albert
        Einstein — and then add the prefix Wikipedia, followed by a colon and
        one space, before the cleaned title.

        Do not rewrite based on the title alone if the URL is not a Wikipedia
        domain.
        """

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

    /// Applies the regex rules only — `.aiPrompt` rules run in a separate
    /// async pass (`AITitleRewriter`).
    nonisolated static func rewrite(title: String, url: String, snapshots: [RewriteRuleSnapshot]) -> String {
        var rewrittenTitle = title

        for rule in sortedSnapshots(snapshots) where rule.isEnabled && rule.kind == .regexMatchReplace {
            if let rewritten = apply(rule: rule, currentTitle: rewrittenTitle, url: url) {
                rewrittenTitle = rewritten
            }
        }

        return rewrittenTitle
    }

    /// The combined natural-language instructions of the enabled AI rules, in
    /// rule order. Empty when no AI rule is enabled.
    nonisolated static func combinedAIInstructions(from snapshots: [RewriteRuleSnapshot]) -> String {
        sortedSnapshots(snapshots)
            .filter { $0.isEnabled && $0.kind == .aiPrompt }
            .map { $0.replacementTemplate.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

        switch snapshot.kind {
        case .aiPrompt:
            if replacement.isEmpty {
                return .invalid(message: "Instructions cannot be empty.")
            }
            return .valid

        case .regexMatchReplace:
            if pattern.isEmpty {
                return .invalid(message: "Pattern cannot be empty.")
            }
            // An empty replacement is allowed: it deletes the matched text.

            do {
                _ = try regex(for: pattern, caseSensitive: snapshot.isCaseSensitive)
            } catch {
                return .invalid(message: "Invalid regex: \(error.localizedDescription)")
            }

            return .valid
        }
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
                replacementTemplate: "github $1/$2",
                isCaseSensitive: false
            ),
            RewriteRule(
                name: "Article Title Rewrite",
                isEnabled: true,
                order: 1,
                kind: .aiPrompt,
                matchField: .title,
                pattern: "",
                replacementTemplate: Self.defaultArticleTitleRewritePrompt,
                isCaseSensitive: false
            ),
            RewriteRule(
                name: "Bitbucket Repo Title",
                isEnabled: true,
                order: 2,
                matchField: .url,
                pattern: #"^https://bitbucket\.org/([^/]+)/([^/?#]+)$"#,
                replacementTemplate: "bitbucket $1/$2",
                isCaseSensitive: false
            ),
            RewriteRule(
                name: "X/Twitter Profile Title",
                isEnabled: true,
                order: 3,
                matchField: .url,
                pattern: #"^https://(?:www\.)?(?:x|twitter)\.com/(?!home$|search$|explore$|notifications$|messages$|settings$|compose$|i$|i/)([A-Za-z0-9_]{1,15})/?$"#,
                replacementTemplate: "x $1",
                isCaseSensitive: false
            ),
            RewriteRule(
                name: "Instagram Profile Title",
                isEnabled: true,
                order: 4,
                matchField: .url,
                pattern: #"^https://(?:www\.)?instagram\.com/(?!explore$|reels$|direct$|accounts$|about$|developer$|legal$)([A-Za-z0-9_.]{1,30})/?$"#,
                replacementTemplate: "instagram $1",
                isCaseSensitive: false
            ),
            RewriteRule(
                name: "Wikipedia Article Rewrite",
                isEnabled: true,
                order: 5,
                kind: .aiPrompt,
                matchField: .title,
                pattern: "",
                replacementTemplate: Self.defaultWikipediaTitleRewritePrompt,
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
