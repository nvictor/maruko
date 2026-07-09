import Combine
import Foundation
import SwiftData

/// Owns the user-editable title rewrite rules — the configuration for what
/// "Format Bookmarks" does to titles.
@MainActor
final class RewriteRulesStore: ObservableObject {
    @Published private(set) var rewriteRules: [RewriteRule] = []
    @Published var errorMessage: String?

    private(set) var modelContext: ModelContext?

    func configure(context: ModelContext) {
        guard modelContext == nil else { return }
        modelContext = context

        do {
            try seedDefaultRulesIfNeeded()
            try migrateLegacyRulesIfNeeded()
            try addMissingDefaultRulesIfNeeded()
            _ = try loadRewriteRules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sendable copies of the enabled, valid rules for off-main formatting.
    func enabledRuleSnapshots() throws -> [RewriteRuleSnapshot] {
        let rules = try loadRewriteRules()
        try validateRulesBeforeApply(rules)
        return rules.filter(\.isEnabled).map(\.snapshot)
    }

    @discardableResult
    func loadRewriteRules() throws -> [RewriteRule] {
        guard let context = modelContext else { return [] }
        let fetched = try context.fetch(FetchDescriptor<RewriteRule>())
        let ordered = BookmarkRewriteEngine.sortedRules(fetched)
        rewriteRules = ordered
        return ordered
    }

    func seedDefaultRulesIfNeeded() throws {
        guard let context = modelContext else { return }
        let existing = try context.fetchCount(FetchDescriptor<RewriteRule>())
        guard existing == 0 else { return }

        for rule in BookmarkRewriteEngine.makeDefaultRules() {
            context.insert(rule)
        }
        try context.save()
    }

    func migrateLegacyRulesIfNeeded() throws {
        guard let context = modelContext else { return }
        let rules = try context.fetch(FetchDescriptor<RewriteRule>())
        var changed = false

        for rule in rules {
            let legacyKind = rule.kindRaw

            if legacyKind == "githubRepoPathToHierarchyTitle" {
                rule.kindRaw = "regexMatchReplace"
                rule.matchField = .url
                rule.pattern = #"^https://github\.com/([^/]+)/([^/?#]+)$"#
                rule.replacementTemplate = "github $1/$2"
                rule.isCaseSensitive = false
                rule.updatedAt = Date()
                changed = true
                continue
            }

            // Drop the "github > owner > repo" breadcrumb style in favor of
            // "github owner/repo" — only touches rules still matching the
            // exact old default, so a user's own edits are left alone.
            if rule.name == "GitHub Repo Title" && rule.replacementTemplate == "github > $1 > $2" {
                rule.replacementTemplate = "github $1/$2"
                rule.updatedAt = Date()
                changed = true
            }

            // The shipped Article prompt's own output-prefix quote ("Article: ")
            // was accidentally parsed by AIRewriteEligibility as a required
            // input substring, silently disabling the rule for virtually every
            // real title. Reset any rule still carrying that exact old prompt
            // to the corrected (quote-free) default — a user's own edits are
            // left alone.
            if rule.name == "Article Title Rewrite" && rule.replacementTemplate == Self.legacyArticlePromptWithAccidentalQuote {
                migrateToDefaultArticleRewrite(rule)
                rule.updatedAt = Date()
                changed = true
            }

            if legacyKind == "containsTextTitleCaseWithPrefix" {
                migrateToDefaultArticleRewrite(rule)
                rule.updatedAt = Date()
                changed = true
                continue
            }

            if rule.name == "Article Title Prefix" && rule.replacementTemplate == "Article $1" {
                migrateToDefaultArticleRewrite(rule)
                rule.updatedAt = Date()
                changed = true
            }

            if rule.name == "Article Title Prefix" && rule.replacementTemplate == "Article ${titlecase:1}" {
                migrateToDefaultArticleRewrite(rule)
                rule.updatedAt = Date()
                changed = true
            }

            if rule.kindRaw.isEmpty {
                rule.kindRaw = "regexMatchReplace"
                rule.updatedAt = Date()
                changed = true
            }
        }

        if changed {
            try context.save()
        }
    }

    /// Inserts any built-in default rule not already present by name. Runs on
    /// every launch (cheap no-op once caught up), so rules added to
    /// `makeDefaultRules()` after a user's rule table was first seeded still
    /// reach their existing install, without touching rules they've already
    /// customized or removed.
    func addMissingDefaultRulesIfNeeded() throws {
        guard let context = modelContext else { return }
        let existingNames = Set(try context.fetch(FetchDescriptor<RewriteRule>()).map(\.name))
        let missing = BookmarkRewriteEngine.makeDefaultRules().filter { !existingNames.contains($0.name) }
        guard !missing.isEmpty else { return }

        let maxOrder = try context.fetch(FetchDescriptor<RewriteRule>()).map(\.order).max() ?? -1
        for (offset, rule) in missing.enumerated() {
            rule.order = maxOrder + 1 + offset
            context.insert(rule)
        }
        try context.save()
    }

    func validateRulesBeforeApply(_ rules: [RewriteRule]) throws {
        let issues = BookmarkRewriteEngine.validate(rules: rules)
        guard !issues.isEmpty else { return }

        let details = issues
            .map { "\($0.ruleName): \($0.message)" }
            .joined(separator: "\n")

        throw NSError(
            domain: "Maruko.RewriteRules",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Fix invalid enabled rewrite rules before applying:\n\(details)"]
        )
    }

    func addRewriteRule(from draft: RewriteRuleDraft) throws {
        guard let context = modelContext else { return }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = draft.replacementTemplate.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            throw NSError(domain: "Maruko.RewriteRules", code: 4, userInfo: [NSLocalizedDescriptionKey: "Rule name cannot be empty."])
        }

        let rule = RewriteRule(
            name: name,
            isEnabled: draft.isEnabled,
            order: draft.order,
            kind: draft.kind,
            matchField: draft.matchField,
            pattern: pattern,
            replacementTemplate: template,
            isCaseSensitive: draft.isCaseSensitive
        )

        switch BookmarkRewriteEngine.validate(rule: rule) {
        case .valid:
            break
        case .invalid(let message):
            throw NSError(domain: "Maruko.RewriteRules", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }

        context.insert(rule)
        try context.save()
        _ = try loadRewriteRules()
    }

    func updateRewriteRule(_ rule: RewriteRule, from draft: RewriteRuleDraft) throws {
        guard let context = modelContext else { return }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            throw NSError(domain: "Maruko.RewriteRules", code: 4, userInfo: [NSLocalizedDescriptionKey: "Rule name cannot be empty."])
        }

        rule.name = name
        rule.isEnabled = draft.isEnabled
        rule.order = draft.order
        rule.kind = draft.kind
        rule.matchField = draft.matchField
        rule.pattern = draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.replacementTemplate = draft.replacementTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.isCaseSensitive = draft.isCaseSensitive
        rule.updatedAt = Date()

        switch BookmarkRewriteEngine.validate(rule: rule) {
        case .valid:
            break
        case .invalid(let message):
            throw NSError(domain: "Maruko.RewriteRules", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }

        try context.save()
        _ = try loadRewriteRules()
    }

    func setRewriteRuleEnabled(_ rule: RewriteRule, isEnabled: Bool) {
        guard let context = modelContext else { return }
        rule.isEnabled = isEnabled
        rule.updatedAt = Date()
        do {
            try context.save()
            _ = try loadRewriteRules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteRewriteRule(_ rule: RewriteRule) {
        guard let context = modelContext else { return }
        context.delete(rule)
        do {
            try context.save()
            try normalizeRuleOrder()
            _ = try loadRewriteRules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveRewriteRule(_ rule: RewriteRule, direction: Int) {
        do {
            var ordered = try loadRewriteRules()
            guard let index = ordered.firstIndex(where: { $0.id == rule.id }) else { return }
            let target = index + direction
            guard ordered.indices.contains(target) else { return }
            ordered.swapAt(index, target)
            try persistRuleOrder(ordered)
            _ = try loadRewriteRules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistRuleOrder(_ ordered: [RewriteRule]) throws {
        guard let context = modelContext else { return }
        for (index, rule) in ordered.enumerated() {
            if rule.order != index {
                rule.order = index
                rule.updatedAt = Date()
            }
        }
        try context.save()
    }

    private func normalizeRuleOrder() throws {
        let ordered = BookmarkRewriteEngine.sortedRules(rewriteRules)
        try persistRuleOrder(ordered)
    }

    private func migrateToDefaultArticleRewrite(_ rule: RewriteRule) {
        rule.name = "Article Title Rewrite"
        rule.kindRaw = RewriteRuleKind.aiPrompt.rawValue
        rule.matchField = .title
        rule.pattern = ""
        rule.replacementTemplate = BookmarkRewriteEngine.defaultArticleTitleRewritePrompt
        rule.isCaseSensitive = false
    }

    /// The exact `defaultArticleTitleRewritePrompt` text as originally
    /// shipped, before its "Prefix exactly with “Article: ”." sentence was
    /// reworded to drop the accidental quoted phrase.
    private static let legacyArticlePromptWithAccidentalQuote = """
        Only rewrite titles that clearly look like article or blog post titles.

        Skip if the title is only a domain, site name, product name, app name, repo name, profile name, documentation section, homepage, or navigation label.

        Skip if the title has fewer than 4 words, unless it contains a clear article headline phrase.

        For matching titles, rewrite using proper title casing. Prefix exactly with “Article: ”.

        Do not rewrite based on the URL alone. The title itself must look like an article headline.
        """
}
