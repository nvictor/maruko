import Foundation
import Testing
@testable import Maruko

struct AITitleRewriterTests {
    private func makeCache() -> AIRewriteCache {
        AIRewriteCache(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ai-cache-\(UUID().uuidString).json")
        )
    }

    private func candidates(_ count: Int) -> [AIRewriteCandidate] {
        (0..<count).map {
            AIRewriteCandidate(guid: "guid-\($0)", title: "title \($0)", url: "https://example.com/\($0)")
        }
    }

    @Test func rewritesInBatchesAndMapsProposalsToGuids() async throws {
        let calls = Counter()
        var rewriter = AITitleRewriter { batch, _ in
            await calls.increment()
            return batch.map { "Clean \($0.title)" }
        }
        rewriter.batchSize = 10

        let overrides = try await rewriter.rewriteTitles(
            candidates: candidates(25),
            instructions: "clean up",
            cache: makeCache()
        )

        #expect(await calls.value == 3)
        #expect(overrides.count == 25)
        #expect(overrides["guid-7"] == "Clean title 7")
    }

    @Test func emptyOversizedAndUnchangedProposalsProduceNoOverride() async throws {
        let rewriter = AITitleRewriter { batch, _ in
            batch.map { candidate in
                switch candidate.guid {
                case "guid-0": return ""
                case "guid-1": return String(repeating: "x", count: 300)
                case "guid-2": return candidate.title
                case "guid-3": return nil
                default: return "Better \(candidate.title)"
                }
            }
        }

        let overrides = try await rewriter.rewriteTitles(
            candidates: candidates(5),
            instructions: "clean up",
            cache: makeCache()
        )

        #expect(overrides.count == 1)
        #expect(overrides["guid-4"] == "Better title 4")
    }

    @Test func refusedBatchKeepsOldTitlesAndContinues() async throws {
        let calls = Counter()
        var rewriter = AITitleRewriter { batch, _ in
            let call = await calls.increment()
            if call == 1 { throw AITitleGenerationError.refused }
            return batch.map { "Clean \($0.title)" }
        }
        rewriter.batchSize = 5

        let overrides = try await rewriter.rewriteTitles(
            candidates: candidates(10),
            instructions: "clean up",
            cache: makeCache()
        )

        // First batch of 5 skipped, second processed.
        #expect(overrides.count == 5)
        #expect(overrides["guid-0"] == nil)
        #expect(overrides["guid-9"] == "Clean title 9")
    }

    @Test func contextOverflowSplitsBatchAndRetries() async throws {
        let sizes = Sizes()
        var rewriter = AITitleRewriter { batch, _ in
            await sizes.record(batch.count)
            if batch.count > 10 { throw AITitleGenerationError.contextOverflow }
            return batch.map { "Clean \($0.title)" }
        }
        rewriter.batchSize = 20

        let overrides = try await rewriter.rewriteTitles(
            candidates: candidates(20),
            instructions: "clean up",
            cache: makeCache()
        )

        #expect(overrides.count == 20)
        #expect(await sizes.values == [20, 10, 10])
    }

    @Test func cacheHitsSkipTheGenerator() async throws {
        let cache = makeCache()
        let calls = Counter()
        let rewriter = AITitleRewriter { batch, _ in
            await calls.increment()
            return batch.map { "Clean \($0.title)" }
        }

        let first = try await rewriter.rewriteTitles(
            candidates: candidates(8),
            instructions: "clean up",
            cache: cache
        )
        let callsAfterFirst = await calls.value
        let second = try await rewriter.rewriteTitles(
            candidates: candidates(8),
            instructions: "clean up",
            cache: cache
        )

        #expect(first == second)
        #expect(await calls.value == callsAfterFirst)
    }

    @Test func changedInstructionsInvalidateTheCache() async throws {
        let cache = makeCache()
        let calls = Counter()
        let rewriter = AITitleRewriter { batch, instructions in
            await calls.increment()
            return batch.map { "\(instructions): \($0.title)" }
        }

        _ = try await rewriter.rewriteTitles(candidates: candidates(3), instructions: "rule A", cache: cache)
        let overrides = try await rewriter.rewriteTitles(candidates: candidates(3), instructions: "rule B", cache: cache)

        #expect(await calls.value == 2)
        #expect(overrides["guid-0"] == "rule B: title 0")
    }

    @Test func cachePersistsAcrossInstances() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-cache-\(UUID().uuidString).json")
        let calls = Counter()
        let rewriter = AITitleRewriter { batch, _ in
            await calls.increment()
            return batch.map { "Clean \($0.title)" }
        }

        _ = try await rewriter.rewriteTitles(
            candidates: candidates(4),
            instructions: "clean up",
            cache: AIRewriteCache(fileURL: fileURL)
        )
        let overrides = try await rewriter.rewriteTitles(
            candidates: candidates(4),
            instructions: "clean up",
            cache: AIRewriteCache(fileURL: fileURL)
        )

        #expect(await calls.value == 1)
        #expect(overrides.count == 4)
    }

    @Test func staleCacheFromOlderPromptVersionIsIgnored() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-cache-\(UUID().uuidString).json")
        let calls = Counter()
        let rewriter = AITitleRewriter { batch, _ in
            await calls.increment()
            return batch.map { "Clean \($0.title)" }
        }

        _ = try await rewriter.rewriteTitles(
            candidates: candidates(3),
            instructions: "clean up",
            cache: AIRewriteCache(fileURL: fileURL, promptVersion: "1")
        )
        _ = try await rewriter.rewriteTitles(
            candidates: candidates(3),
            instructions: "clean up",
            cache: AIRewriteCache(fileURL: fileURL, promptVersion: "2")
        )

        // The v1 entries must not satisfy v2 lookups.
        #expect(await calls.value == 2)
    }

    @Test func skippedItemsAreCachedAsKeepOld() async throws {
        let cache = makeCache()
        let calls = Counter()
        // Generator changes nothing (conditional rule matched no titles).
        let rewriter = AITitleRewriter { batch, _ in
            await calls.increment()
            return batch.map { _ in nil }
        }

        let first = try await rewriter.rewriteTitles(
            candidates: candidates(6),
            instructions: "only titles containing article",
            cache: cache
        )
        let second = try await rewriter.rewriteTitles(
            candidates: candidates(6),
            instructions: "only titles containing article",
            cache: cache
        )

        #expect(first.isEmpty && second.isEmpty)
        // The skip decision is cached: the second run never hits the model.
        #expect(await calls.value == 1)
    }

    @Test func emptyInstructionsOrCandidatesShortCircuit() async throws {
        let rewriter = AITitleRewriter { _, _ in
            Issue.record("generator should not be called")
            return []
        }

        let noInstructions = try await rewriter.rewriteTitles(
            candidates: candidates(3),
            instructions: "   ",
            cache: makeCache()
        )
        let noCandidates = try await rewriter.rewriteTitles(
            candidates: [],
            instructions: "clean up",
            cache: makeCache()
        )

        #expect(noInstructions.isEmpty)
        #expect(noCandidates.isEmpty)
    }

    @Test func reportsMonotonicProgress() async throws {
        var rewriter = AITitleRewriter { batch, _ in batch.map { "Clean \($0.title)" } }
        rewriter.batchSize = 4
        let progress = LockedRecorder()

        _ = try await rewriter.rewriteTitles(
            candidates: candidates(10),
            instructions: "clean up",
            cache: makeCache(),
            progress: { processed, total in
                progress.record(processed * 100 + total)
            }
        )

        // Encoded as processed*100 + total: 0, 4, 8, then 10 of 10.
        #expect(progress.values == [10, 410, 810, 1010])
    }
}

private final class LockedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

private actor Counter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

private actor Sizes {
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }
}
