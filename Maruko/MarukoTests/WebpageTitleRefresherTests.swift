import Foundation
import SwiftData
import Testing
@testable import Maruko

struct WebpageTitleRefresherTests {
    private func response(
        url: URL,
        status: Int = 200,
        contentType: String = "text/html; charset=utf-8"
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    @Test func extractsHTMLTitleAndNormalizesIt() async throws {
        let refresher = WebpageTitleRefresher { request, _ in
            let html = "<HTML><HEAD><TiTlE>  Rice &amp; Beans\n Guide &#x2014; Home </TiTlE></HEAD></HTML>"
            return (Data(html.utf8), response(url: request.url!))
        }

        let titles = try await refresher.refresh(candidates: [
            WebpageTitleCandidate(nodeID: "1", url: "https://example.com")
        ])

        #expect(titles == ["1": "Rice & Beans Guide — Home"])
    }

    @Test func skipsInvalidSchemesAndIndividualFailures() async throws {
        let refresher = WebpageTitleRefresher { request, _ in
            if request.url?.host == "failed.example" { throw URLError(.timedOut) }
            let html = "<title>Working</title>"
            return (Data(html.utf8), response(url: request.url!))
        }

        let titles = try await refresher.refresh(candidates: [
            WebpageTitleCandidate(nodeID: "file", url: "file:///tmp/page.html"),
            WebpageTitleCandidate(nodeID: "failed", url: "https://failed.example"),
            WebpageTitleCandidate(nodeID: "ok", url: "https://ok.example")
        ])

        #expect(titles == ["ok": "Working"])
    }

    @Test func rejectsHTTPFailuresNonHTMLMissingAndOversizedTitles() async throws {
        let refresher = WebpageTitleRefresher { request, _ in
            let url = request.url!
            switch url.host {
            case "http.example":
                return (Data("<title>No</title>".utf8), response(url: url, status: 500))
            case "json.example":
                return (Data("{\"title\":\"No\"}".utf8), response(url: url, contentType: "application/json"))
            case "missing.example":
                return (Data("<html></html>".utf8), response(url: url))
            default:
                return (Data("<title>\(String(repeating: "x", count: 501))</title>".utf8), response(url: url))
            }
        }
        let candidates = ["http", "json", "missing", "long"].map {
            WebpageTitleCandidate(nodeID: $0, url: "https://\($0).example")
        }
        #expect(try await refresher.refresh(candidates: candidates).isEmpty)
    }

    @Test func oldFormatOptionsDecodeWithRefreshDisabled() throws {
        let oldJSON = #"{"removeDuplicates":false,"rewriteTitles":true,"moveRecentToTop":false,"recencyWindowDays":90}"#
        let options = try JSONDecoder().decode(FormatOptions.self, from: Data(oldJSON.utf8))
        #expect(!options.removeDuplicates)
        #expect(options.rewriteTitles)
        #expect(!options.refreshTitlesFromWebpages)
        #expect(!options.moveRecentToTop)
        #expect(options.recencyWindowDays == 90)
    }

    @Test @MainActor func obsoleteAIRulesAreDeletedAndRegexRulesSurvive() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RewriteRule.self, configurations: configuration)
        let context = container.mainContext
        let regex = RewriteRule(
            name: "My regex", order: 0, matchField: .title,
            pattern: "old", replacementTemplate: "new"
        )
        let ai = RewriteRule(
            name: "My AI rule", order: 1, matchField: .title,
            pattern: "", replacementTemplate: "Use sentence case"
        )
        ai.kindRaw = "aiPrompt"
        context.insert(regex)
        context.insert(ai)
        try context.save()

        let store = RewriteRulesStore()
        store.configure(context: context)
        let remaining = try context.fetch(FetchDescriptor<RewriteRule>())

        #expect(remaining.contains { $0.id == regex.id })
        #expect(!remaining.contains { $0.id == ai.id })
        #expect(remaining.allSatisfy { $0.kindRaw == "regexMatchReplace" })
    }
}
