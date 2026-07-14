import Combine
import Foundation
import SwiftData

/// Owns the user-editable title rewrite rules. The configuration for what
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
            try removeObsoleteAIRules()
            try seedDefaultRulesIfNeeded()
            try migrateLegacyRulesIfNeeded()
            try addMissingDefaultRulesIfNeeded()
            _ = try loadRewriteRules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes records created by every shipped AI-rule representation.
    /// `kindRaw` remains in the persisted model for lightweight-store
    /// compatibility, but is no longer part of the app's rule interface.
    func removeObsoleteAIRules() throws {
        guard let context = modelContext else { return }
        let rules = try context.fetch(FetchDescriptor<RewriteRule>())
        let obsoleteKinds = Set(["aiPrompt", "containsTextTitleCaseWithPrefix"])
        let obsoleteNames = Set(["Article Title Rewrite", "Article Title Prefix", "Wikipedia Article Rewrite"])
        let obsolete = rules.filter {
            obsoleteKinds.contains($0.kindRaw) || obsoleteNames.contains($0.name)
        }
        guard !obsolete.isEmpty else { return }
        for rule in obsolete { context.delete(rule) }
        try context.save()
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
            // "github owner/repo". Only touches rules still matching the
            // exact old default, so a user's own edits are left alone.
            if rule.name == "GitHub Repo Title" && rule.replacementTemplate == "github > $1 > $2" {
                rule.replacementTemplate = "github $1/$2"
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

}
