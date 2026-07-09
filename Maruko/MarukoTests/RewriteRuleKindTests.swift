import Foundation
import Testing
@testable import Maruko

struct RewriteRuleKindTests {
    private func snapshot(kind: RewriteRuleKind, pattern: String, template: String) -> RewriteRuleSnapshot {
        RewriteRuleSnapshot(
            id: UUID(),
            name: "Rule",
            isEnabled: true,
            order: 0,
            kind: kind,
            matchField: .title,
            pattern: pattern,
            replacementTemplate: template,
            isCaseSensitive: false,
            createdAt: Date()
        )
    }

    @Test func aiRuleValidationRequiresInstructionsOnly() {
        let valid = snapshot(kind: .aiPrompt, pattern: "", template: "Use sentence case.")
        if case .invalid(let message) = BookmarkRewriteEngine.validate(snapshot: valid, name: "Rule") {
            Issue.record("expected valid, got: \(message)")
        }

        let missingInstructions = snapshot(kind: .aiPrompt, pattern: "irrelevant", template: "  ")
        guard case .invalid = BookmarkRewriteEngine.validate(snapshot: missingInstructions, name: "Rule") else {
            Issue.record("expected invalid for empty instructions")
            return
        }
    }

    @Test func regexRewriteIgnoresAIRules() {
        let aiRule = snapshot(kind: .aiPrompt, pattern: "", template: "Would clobber everything")
        let title = BookmarkRewriteEngine.rewrite(
            title: "Untouched",
            url: "https://example.com/",
            snapshots: [aiRule]
        )
        #expect(title == "Untouched")
    }

    @Test func combinedInstructionsJoinEnabledAIRulesInOrder() {
        let first = RewriteRuleSnapshot(
            id: UUID(), name: "A", isEnabled: true, order: 0, kind: .aiPrompt,
            matchField: .title, pattern: "", replacementTemplate: "First rule.",
            isCaseSensitive: false, createdAt: Date()
        )
        let disabled = RewriteRuleSnapshot(
            id: UUID(), name: "B", isEnabled: false, order: 1, kind: .aiPrompt,
            matchField: .title, pattern: "", replacementTemplate: "Disabled rule.",
            isCaseSensitive: false, createdAt: Date()
        )
        let second = RewriteRuleSnapshot(
            id: UUID(), name: "C", isEnabled: true, order: 2, kind: .aiPrompt,
            matchField: .title, pattern: "", replacementTemplate: "Second rule.",
            isCaseSensitive: false, createdAt: Date()
        )
        let regex = snapshot(kind: .regexMatchReplace, pattern: "x", template: "y")

        let combined = BookmarkRewriteEngine.combinedAIInstructions(
            from: [second, regex, disabled, first]
        )
        #expect(combined == "First rule.\nSecond rule.")
    }

    @Test @MainActor func defaultArticleRuleUsesSafeAIPrompt() {
        let rules = BookmarkRewriteEngine.makeDefaultRules()
        let article = rules.first { $0.name == "Article Title Rewrite" }

        #expect(article?.kind == .aiPrompt)
        #expect(article?.pattern.isEmpty == true)
        #expect(article?.replacementTemplate == BookmarkRewriteEngine.defaultArticleTitleRewritePrompt)
    }

    @Test func defaultArticlePromptDoesNotGateEligibilityOnItsOwnOutputPrefix() {
        // The prompt's "Skip if..." sentences already satisfy
        // AIRewriteEligibility's "title"/"skip"/"contain" trigger words, so
        // any quoted phrase in the combined text becomes a required input
        // substring. The prompt's own output prefix must never be quoted.
        // that would make this (and virtually every other real title)
        // ineligible before the model ever sees it, exactly as it did when
        // the prefix instruction read `Prefix exactly with "Article: ".`.
        let eligibility = AIRewriteEligibility(instructions: BookmarkRewriteEngine.defaultArticleTitleRewritePrompt)
        let candidate = AIRewriteCandidate(
            guid: "recipe",
            title: "How to Cook Rice the Right Way",
            url: "https://example.com/rice"
        )
        #expect(eligibility.allows(candidate))
    }

    @Test @MainActor func defaultRulesCombinedEligibilityDoesNotRequireArticlePrefix() {
        // End-to-end with the real shipped default rule set (Article +
        // Wikipedia), an ordinary article title must still reach the model.
        let snapshots = BookmarkRewriteEngine.makeDefaultRules().map(\.snapshot)
        let combined = BookmarkRewriteEngine.combinedAIInstructions(from: snapshots)
        let eligibility = AIRewriteEligibility(instructions: combined)
        let candidate = AIRewriteCandidate(
            guid: "recipe",
            title: "How to Cook Rice the Right Way",
            url: "https://example.com/rice"
        )
        #expect(eligibility.allows(candidate))
    }

    @Test @MainActor func unknownKindRawFallsBackToRegex() {
        let rule = RewriteRule(
            name: "Legacy",
            order: 0,
            matchField: .title,
            pattern: "a",
            replacementTemplate: "b"
        )
        rule.kindRaw = "someFutureKind"
        #expect(rule.kind == .regexMatchReplace)
    }

    @Test @MainActor func draftRoundTripsKind() {
        let rule = RewriteRule(
            name: "AI Rule",
            order: 0,
            kind: .aiPrompt,
            matchField: .title,
            pattern: "",
            replacementTemplate: "Instructions here"
        )
        let draft = RewriteRuleDraft(rule: rule)
        #expect(draft.kind == .aiPrompt)
        #expect(rule.snapshot.kind == .aiPrompt)
    }
}
