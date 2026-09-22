import Foundation
import Testing
@testable import Maruko

struct RoutineClassifierTests {
    @Test func matchesHostExactPersonalShopping() {
        let match = RoutineClassifier.classify(url: "https://www.amazon.com/gp/cart", title: "Cart")
        #expect(match?.category == .personal)
        #expect(match?.strength == .hostExact)
        #expect(match?.label == "Shopping")
    }

    @Test func matchesHostExactWorkCloudConsole() {
        let match = RoutineClassifier.classify(url: "https://console.aws.amazon.com/ec2/home", title: "EC2")
        #expect(match?.category == .work)
        #expect(match?.strength == .hostExact)
        #expect(match?.label == "Cloud Console")
    }

    @Test func matchesRegistrableSuffixSubdomain() {
        let match = RoutineClassifier.classify(url: "https://team.atlassian.net/browse/ABC-1", title: "ABC-1")
        #expect(match?.category == .work)
        #expect(match?.strength == .hostExact)
        #expect(match?.label == "Work Collaboration")
    }

    @Test func matchesHostKeywordForSelfHostedTool() {
        let match = RoutineClassifier.classify(url: "https://grafana.internal.example.com/d/xyz", title: "Dashboard")
        #expect(match?.category == .work)
        #expect(match?.strength == .hostKeyword)
        #expect(match?.label == "Observability")
    }

    @Test func matchesTitleKeywordWhenHostIsAmbiguous() {
        let match = RoutineClassifier.classify(url: "https://portal.internal.example.com/login", title: "MyChart Sign In")
        #expect(match?.category == .personal)
        #expect(match?.strength == .titleKeyword)
        #expect(match?.label == "Health")
    }

    @Test func returnsNilForUnknownSite() {
        #expect(RoutineClassifier.classify(url: "https://example.com/", title: "Example") == nil)
    }

    @Test func isCaseInsensitiveAndStripsWwwPrefix() {
        let match = RoutineClassifier.classify(url: "https://WWW.Chase.COM/login", title: "Sign In")
        #expect(match?.category == .personal)
        #expect(match?.strength == .hostExact)
        #expect(match?.label == "Banking")
    }

    @Test func prefersHostExactOverTitleKeywordWhenBothMatch() {
        // Host matches Banking (hostExact); title happens to also contain a
        // titleKeyword substring. Host wins: the tier is strictly higher.
        let match = RoutineClassifier.classify(url: "https://chase.com/", title: "MyChart-style dashboard")
        #expect(match?.strength == .hostExact)
        #expect(match?.label == "Banking")
    }

    @Test func handlesNilURLByFallingBackToTitleKeyword() {
        let match = RoutineClassifier.classify(url: nil, title: "Print your boarding pass")
        #expect(match?.category == .personal)
        #expect(match?.strength == .titleKeyword)
        #expect(match?.label == "Travel")
    }

    @Test func handlesMalformedURLWithoutCrashing() {
        #expect(RoutineClassifier.classify(url: "not a url ::: %%", title: "Whatever") == nil)
    }
}
