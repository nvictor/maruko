import Foundation
import Testing
@testable import Maruko

struct DefaultRewriteRulesTests {
    private let snapshots = BookmarkRewriteEngine.makeDefaultRules().map(\.snapshot)

    private func rewritten(title: String, url: String) -> String {
        BookmarkRewriteEngine.rewrite(title: title, url: url, snapshots: snapshots)
    }

    @Test func defaultRulesIncludeExpectedNames() {
        let names = BookmarkRewriteEngine.makeDefaultRules().map(\.name)
        #expect(names == [
            "GitHub Repo Title",
            "Article Title Rewrite",
            "Bitbucket Repo Title",
            "X/Twitter Profile Title",
            "Instagram Profile Title",
            "Wikipedia Article Rewrite",
        ])
    }

    @Test func gitHubRepoTitleUsesOwnerSlashRepoFormat() {
        #expect(rewritten(title: "GitHub", url: "https://github.com/nvictor/maruko") == "github nvictor/maruko")
    }

    @Test func bitbucketRepoTitleMatchesRepoURLs() {
        #expect(rewritten(title: "Bitbucket", url: "https://bitbucket.org/nvictor/maruko") == "bitbucket nvictor/maruko")
    }

    @Test func bitbucketRepoTitleIgnoresNonRepoURLs() {
        #expect(rewritten(title: "Unchanged", url: "https://bitbucket.org/nvictor") == "Unchanged")
        #expect(rewritten(title: "Unchanged", url: "https://bitbucket.org/nvictor/maruko/src/main") == "Unchanged")
    }

    @Test func twitterProfileTitleMatchesBothHostnames() {
        #expect(rewritten(title: "nvictor / X", url: "https://x.com/nvictor") == "x nvictor")
        #expect(rewritten(title: "nvictor / Twitter", url: "https://twitter.com/nvictor") == "x nvictor")
        #expect(rewritten(title: "nvictor / X", url: "https://www.x.com/nvictor") == "x nvictor")
        #expect(rewritten(title: "nvictor / X", url: "https://x.com/nvictor/") == "x nvictor")
    }

    @Test func twitterProfileTitleIgnoresReservedRoutesAndMultiSegmentPaths() {
        for url in [
            "https://x.com/home",
            "https://x.com/search",
            "https://x.com/explore",
            "https://x.com/notifications",
            "https://x.com/messages",
            "https://x.com/settings",
            "https://x.com/compose",
            "https://x.com/i/bookmarks",
            "https://x.com/nvictor/status/12345",
        ] {
            #expect(rewritten(title: "Unchanged", url: url) == "Unchanged")
        }
    }

    @Test func instagramProfileTitleMatchesProfileURLs() {
        #expect(rewritten(title: "nvictor • Instagram", url: "https://instagram.com/nvictor") == "instagram nvictor")
        #expect(rewritten(title: "nvictor • Instagram", url: "https://www.instagram.com/nvictor/") == "instagram nvictor")
    }

    @Test func instagramProfileTitleIgnoresReservedRoutesAndPostURLs() {
        for url in [
            "https://instagram.com/explore",
            "https://instagram.com/reels",
            "https://instagram.com/direct",
            "https://instagram.com/accounts",
            "https://instagram.com/p/ABC123/",
            "https://instagram.com/reel/ABC123/",
        ] {
            #expect(rewritten(title: "Unchanged", url: url) == "Unchanged")
        }
    }

    @Test func wikipediaPromptEligibilityAllowsRealWikipediaTitles() {
        let combined = BookmarkRewriteEngine.combinedAIInstructions(from: snapshots)
        let eligibility = AIRewriteEligibility(instructions: combined)
        let candidate = AIRewriteCandidate(
            guid: "einstein",
            title: "Albert Einstein - Wikipedia",
            url: "https://en.wikipedia.org/wiki/Albert_Einstein"
        )
        #expect(eligibility.allows(candidate))
    }
}
