import Foundation
import Testing
@testable import Maruko

struct DefaultRewriteRulesTests {
    private let snapshots = BookmarkRewriteEngine.makeDefaultRules().map(\.snapshot)

    private func rewritten(title: String, url: String) -> String {
        BookmarkRewriteEngine.rewrite(title: title, url: url, snapshots: snapshots)
    }

    @Test func firstMatchingDeterministicRuleStopsFurtherRewrites() {
        let now = Date()
        let rules = [
            RewriteRuleSnapshot(
                id: UUID(), name: "First", isEnabled: true, order: 0,
                matchField: .title,
                pattern: "Original", replacementTemplate: "First Result",
                isCaseSensitive: true, createdAt: now
            ),
            RewriteRuleSnapshot(
                id: UUID(), name: "Second", isEnabled: true, order: 1,
                matchField: .title,
                pattern: "First Result", replacementTemplate: "Second Result",
                isCaseSensitive: true, createdAt: now
            ),
        ]

        #expect(BookmarkRewriteEngine.rewrite(title: "Original", url: "", snapshots: rules) == "First Result")
    }

    @Test func defaultRulesIncludeExpectedNames() {
        let names = BookmarkRewriteEngine.makeDefaultRules().map(\.name)
        #expect(names == [
            "GitHub Repo Title",
            "Bitbucket Repo Title",
            "X/Twitter Profile Title",
            "Instagram Profile Title",
            "GitLab Repo Title",
            "Wikipedia Article Title",
            "Naked Domain Title",
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

    @Test func gitLabRepoTitleMatchesRepoURLs() {
        #expect(rewritten(title: "GitLab", url: "https://gitlab.com/nvictor/maruko") == "gitlab nvictor/maruko")
    }

    @Test func gitLabRepoTitleIgnoresNonRepoURLs() {
        #expect(rewritten(title: "Unchanged", url: "https://gitlab.com/nvictor") == "Unchanged")
        #expect(rewritten(title: "Unchanged", url: "https://gitlab.com/explore/projects/trending") == "Unchanged")
    }

    @Test func wikipediaArticleTitleFormatsArticleSlugs() {
        #expect(rewritten(
            title: "A* search algorithm - Wikipedia",
            url: "https://en.wikipedia.org/wiki/A*_search_algorithm"
        ) == "wikipedia A* search algorithm")
        #expect(rewritten(
            title: "Bézier curve - Wikipedia",
            url: "https://en.wikipedia.org/wiki/B%C3%A9zier_curve"
        ) == "wikipedia Bézier curve")
    }

    @Test func wikipediaArticleTitleMatchesMobileAndOtherLanguages() {
        #expect(rewritten(
            title: "Ada Lovelace - Wikipedia",
            url: "https://en.m.wikipedia.org/wiki/Ada_Lovelace"
        ) == "wikipedia Ada Lovelace")
        #expect(rewritten(
            title: "Courbe de Bézier — Wikipédia",
            url: "https://fr.wikipedia.org/wiki/Courbe_de_B%C3%A9zier"
        ) == "wikipedia Courbe de Bézier")
        #expect(rewritten(
            title: "Algorithmique — Wikipédia",
            url: "https://fr.m.wikipedia.org/wiki/Algorithmique"
        ) == "wikipedia Algorithmique")
    }

    @Test func wikipediaArticleTitleIgnoresNonArticleURLs() {
        #expect(rewritten(
            title: "Unchanged",
            url: "https://en.wikipedia.org/w/index.php?title=Ada_Lovelace"
        ) == "Unchanged")
    }

    @Test func nakedDomainTitleMatchesBareHosts() {
        #expect(rewritten(title: "Example", url: "https://example.com") == "example.com")
        #expect(rewritten(title: "Example", url: "http://www.example.com/") == "example.com")
        #expect(rewritten(title: "Example", url: "https://sub.example.com") == "sub.example.com")
    }

    @Test func nakedDomainTitleIgnoresURLsWithPaths() {
        #expect(rewritten(title: "Unchanged", url: "https://example.com/path") == "Unchanged")
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

}
