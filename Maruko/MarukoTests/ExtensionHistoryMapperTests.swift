import Foundation
import Testing
@testable import Maruko

struct ExtensionHistoryMapperTests {
    private typealias Visit = ExtensionSessionPayload.HistoryVisit

    @Test func convertsMillisecondEpochAndNormalizesURLs() throws {
        let visits = ExtensionHistoryMapper.recentVisits(
            history: [Visit(url: "HTTPS://GitHub.com/Owner/Repo?b=2&a=1", lastVisitTime: 1_751_400_000_000)],
            cutoff: Date(timeIntervalSince1970: 0)
        )

        let expectedKey = try #require(URLNormalizer.normalize("https://github.com/Owner/Repo?a=1&b=2"))
        #expect(visits[expectedKey] == Date(timeIntervalSince1970: 1_751_400_000))
    }

    @Test func mostRecentVisitWinsForTheSameURL() throws {
        let key = try #require(URLNormalizer.normalize("https://example.com/page"))
        let visits = ExtensionHistoryMapper.recentVisits(
            history: [
                Visit(url: "https://example.com/page", lastVisitTime: 2_000_000),
                Visit(url: "https://example.com/page/", lastVisitTime: 9_000_000),
                Visit(url: "https://example.com/page", lastVisitTime: 5_000_000),
            ],
            cutoff: Date(timeIntervalSince1970: 0)
        )

        #expect(visits[key] == Date(timeIntervalSince1970: 9_000))
        #expect(visits.count == 1)
    }

    @Test func visitsBeforeTheCutoffAreDropped() {
        let visits = ExtensionHistoryMapper.recentVisits(
            history: [
                Visit(url: "https://old.example.com/", lastVisitTime: 1_000_000),
                Visit(url: "https://new.example.com/", lastVisitTime: 900_000_000_000),
            ],
            cutoff: Date(timeIntervalSince1970: 500_000)
        )

        #expect(visits.count == 1)
        #expect(visits.keys.first?.contains("new.example.com") == true)
    }

    @Test func unparseableURLsAreDropped() {
        let visits = ExtensionHistoryMapper.recentVisits(
            history: [Visit(url: "   ", lastVisitTime: 900_000_000_000)],
            cutoff: Date(timeIntervalSince1970: 0)
        )

        #expect(visits.isEmpty)
    }
}
