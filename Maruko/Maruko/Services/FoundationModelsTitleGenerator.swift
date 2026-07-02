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
        @Guide(description: "The rewritten title for that bookmark")
        var title: String
    }

    static let generate: AITitleRewriter.Generator = { batch, instructions in
        // A fresh session per batch keeps each request small and independent;
        // sessions accumulate their transcript toward the context window.
        let session = LanguageModelSession(instructions: """
            You clean up browser bookmark titles. Rewrite each numbered bookmark \
            title following these rules:

            \(instructions)

            Keep each title's meaning. Do not invent information that is not in \
            the title or URL. Keep titles concise. Return one rewritten title \
            per bookmark, using each bookmark's number.
            """)

        let prompt = batch.enumerated()
            .map { index, candidate in "\(index). \(candidate.title) — \(candidate.url.prefix(120))" }
            .joined(separator: "\n")

        do {
            let response = try await session.respond(to: prompt, generating: [RetitledItem].self)
            var proposals = [String?](repeating: nil, count: batch.count)
            for item in response.content where proposals.indices.contains(item.index) {
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
