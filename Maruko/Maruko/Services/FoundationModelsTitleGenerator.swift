import Foundation
import FoundationModels

/// The production `AITitleRewriter.Generator`: Apple's on-device language
/// model via the FoundationModels framework. Everything else in the AI
/// rewrite pipeline is model-agnostic; only this file imports the framework.
nonisolated enum FoundationModelsTitleGenerator {
    /// Nil when the model can be used; otherwise a human-readable reason for
    /// the "AI rules skipped" notice.
    static func availabilityNotice() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Enable it in System Settings to use AI rewrite rules."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading. AI rewrite rules were skipped for now."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, so AI rewrite rules were skipped."
        case .unavailable:
            return "Apple Intelligence isn't available right now, so AI rewrite rules were skipped."
        }
    }

    @Generable
    struct RetitledItem {
        @Guide(description: "The number of the bookmark in the list")
        var index: Int
        @Guide(description: "Quote the exact part of the title that makes the user's rules apply to this bookmark")
        var evidence: String
        @Guide(description: "The rewritten title for that bookmark")
        var title: String
    }

    static let generate: AITitleRewriter.Generator = { batch, instructions in
        // A fresh session per batch keeps each request small and independent;
        // sessions accumulate their transcript toward the context window.
        // "No change" must be the default: user rules are often conditional
        // ("only titles that contain …"), and a prompt that demands one
        // rewrite per item makes the model prefix everything.
        let session = LanguageModelSession(instructions: """
            You selectively clean up browser bookmark titles. The user's rules \
            are:

            \(instructions)

            The rules may apply to only some of the bookmarks. For each \
            numbered bookmark, decide whether the rules apply to its title. \
            Return entries ONLY for bookmarks whose titles the rules change, \
            and for each one quote the exact evidence in the title that made \
            the rules apply. Skip every bookmark you cannot quote evidence \
            for; when in doubt, skip. If no titles need changing, return an \
            empty list. Keep each rewritten title's meaning; do not invent \
            information that is not in the title or URL.
            """)

        let prompt = batch.enumerated()
            .map { index, candidate in "\(index). \(candidate.title). URL: \(candidate.url.prefix(120))" }
            .joined(separator: "\n")

        do {
            let response = try await session.respond(to: prompt, generating: [RetitledItem].self)
            var proposals = [String?](repeating: nil, count: batch.count)
            for item in response.content where proposals.indices.contains(item.index) {
                // Structural check on the model's own justification: the
                // quoted evidence must actually appear in the original title
                // (or URL, for URL-based rules). A fabricated match. The
                // usual failure mode for conditional rules. Can't pass this.
                let evidence = item.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                let candidate = batch[item.index]
                guard !evidence.isEmpty,
                      candidate.title.localizedCaseInsensitiveContains(evidence)
                        || candidate.url.localizedCaseInsensitiveContains(evidence) else {
                    continue
                }
                proposals[item.index] = item.title
            }
            return proposals
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw AITitleGenerationError.contextOverflow
            default:
                throw AITitleGenerationError.refused
            }
        }
    }
}
