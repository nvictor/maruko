import Foundation
import Testing
@testable import Maruko

struct RegexExampleTests {
    private func snapshot(for example: RegexExample) -> RewriteRuleSnapshot {
        RewriteRuleSnapshot(
            id: UUID(),
            name: example.name,
            isEnabled: true,
            order: 0,
            matchField: example.matchField,
            pattern: example.pattern,
            replacementTemplate: example.replacement,
            isCaseSensitive: false,
            createdAt: Date()
        )
    }

    @Test(arguments: RegexExample.all)
    func exampleValidates(_ example: RegexExample) {
        if case .invalid(let message) = BookmarkRewriteEngine.validate(
            snapshot: snapshot(for: example),
            name: example.name
        ) {
            Issue.record("\(example.name) is invalid: \(message)")
        }
    }

    @Test(arguments: RegexExample.all)
    func exampleProducesItsAdvertisedResult(_ example: RegexExample) {
        let rewritten = BookmarkRewriteEngine.rewrite(
            title: example.sampleTitle,
            url: example.sampleURL,
            snapshots: [snapshot(for: example)]
        )
        #expect(rewritten == example.expectedResult, "\(example.name)")
    }

    @Test func emptyReplacementIsValidForRegexRules() {
        let deletion = RewriteRuleSnapshot(
            id: UUID(),
            name: "Delete match",
            isEnabled: true,
            order: 0,
            matchField: .title,
            pattern: #"\s*\(draft\)"#,
            replacementTemplate: "",
            isCaseSensitive: false,
            createdAt: Date()
        )
        if case .invalid(let message) = BookmarkRewriteEngine.validate(snapshot: deletion, name: "Delete match") {
            Issue.record("empty replacement should be valid for regex rules: \(message)")
        }
        #expect(
            BookmarkRewriteEngine.rewrite(title: "Set list (draft)", url: "", snapshots: [deletion]) == "Set list"
        )
    }

    @Test func previewSnapshotRoundTripsDraftFields() {
        var draft = RewriteRuleDraft.default
        draft.name = "Title cleanup"
        draft.replacementTemplate = "Clean title"
        draft.matchField = .url
        draft.isCaseSensitive = true

        let snapshot = draft.previewSnapshot()
        #expect(snapshot.name == "Title cleanup")
        #expect(snapshot.replacementTemplate == "Clean title")
        #expect(snapshot.matchField == .url)
        #expect(snapshot.isCaseSensitive)
        #expect(snapshot.isEnabled)
    }
}
