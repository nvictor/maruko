import CryptoKit
import Foundation

nonisolated struct AIRewriteCandidate: Equatable, Sendable {
    let guid: String
    let title: String
    let url: String
}

/// Control-flow errors a generator can throw per batch. Anything else also
/// skips the batch; these two get distinct handling (overflow retries with a
/// smaller batch).
nonisolated enum AITitleGenerationError: Error {
    case contextOverflow
    case refused
}

/// Persistent guid+title+instructions → proposed-title cache, so a title the
/// model already processed never goes back to it. Analysis re-runs on every
/// option change; without this every re-run would redo minutes of on-device
/// generation. Survives cancellation (flushed after every batch).
nonisolated final class AIRewriteCache: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = stored
        } else {
            entries = [:]
        }
    }

    static func defaultCache() -> AIRewriteCache {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maruko", isDirectory: true)
        return AIRewriteCache(fileURL: base.appendingPathComponent("ai-title-cache.json"))
    }

    func proposal(guid: String, title: String, instructions: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Self.key(guid: guid, title: title, instructions: instructions)]
    }

    func store(proposal: String, guid: String, title: String, instructions: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[Self.key(guid: guid, title: title, instructions: instructions)] = proposal
    }

    func flush() {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL)
    }

    private static func key(guid: String, title: String, instructions: String) -> String {
        let titleHash = SHA256.hash(data: Data(title.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let instructionsHash = SHA256.hash(data: Data(instructions.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "\(guid)|\(titleHash)|\(instructionsHash)"
    }
}

/// Batches recently opened bookmarks through a title generator (the on-device
/// Apple Intelligence model in production, a fake in tests) and returns
/// guid → new title for every title the generator actually changed.
nonisolated struct AITitleRewriter {
    /// Returns one proposal per batch item, aligned by position; nil means no
    /// proposal for that item.
    typealias Generator = @Sendable (_ batch: [AIRewriteCandidate], _ instructions: String) async throws -> [String?]

    static let minimumBatchSize = 5
    static let maximumTitleLength = 200

    var batchSize = 25
    let generate: Generator

    func rewriteTitles(
        candidates: [AIRewriteCandidate],
        instructions: String,
        cache: AIRewriteCache,
        progress: @Sendable (_ processed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> [String: String] {
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty, !candidates.isEmpty else { return [:] }

        var overrides: [String: String] = [:]
        var pending: [AIRewriteCandidate] = []

        for candidate in candidates {
            if let cached = cache.proposal(guid: candidate.guid, title: candidate.title, instructions: instructions) {
                if cached != candidate.title {
                    overrides[candidate.guid] = cached
                }
            } else {
                pending.append(candidate)
            }
        }

        let total = candidates.count
        var processed = total - pending.count
        progress(processed, total)

        var queue: [[AIRewriteCandidate]] = stride(from: 0, to: pending.count, by: batchSize).map {
            Array(pending[$0..<min($0 + batchSize, pending.count)])
        }

        while !queue.isEmpty {
            try Task.checkCancellation()
            let batch = queue.removeFirst()

            let proposals: [String?]
            do {
                proposals = try await generate(batch, instructions)
            } catch is CancellationError {
                throw CancellationError()
            } catch AITitleGenerationError.contextOverflow where batch.count > Self.minimumBatchSize {
                // Too much text for one request: retry as two smaller batches.
                let middle = batch.count / 2
                queue.insert(Array(batch[middle...]), at: 0)
                queue.insert(Array(batch[..<middle]), at: 0)
                continue
            } catch {
                // Refused or failed batch: keep the old titles and move on.
                processed += batch.count
                progress(processed, total)
                continue
            }

            for (candidate, proposal) in zip(batch, proposals) {
                guard let accepted = Self.sanitize(proposal, original: candidate.title) else { continue }
                cache.store(
                    proposal: accepted,
                    guid: candidate.guid,
                    title: candidate.title,
                    instructions: instructions
                )
                if accepted != candidate.title {
                    overrides[candidate.guid] = accepted
                }
            }
            cache.flush()

            processed += batch.count
            progress(processed, total)
        }

        return overrides
    }

    /// Returns the usable title, or nil when the proposal should be ignored
    /// (and not cached, so a later run may retry).
    private static func sanitize(_ proposal: String?, original: String) -> String? {
        guard let proposal else { return nil }
        let trimmed = proposal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumTitleLength else { return nil }
        return trimmed
    }
}
