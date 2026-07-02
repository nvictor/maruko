import Foundation

/// Curated regex presets shown in the rule editor's "Insert Example" menu.
/// Each one fills the pattern/replacement fields and the Try-it sample so the
/// live preview demonstrates the rewrite immediately.
nonisolated struct RegexExample: Identifiable, Sendable {
    let name: String
    let pattern: String
    let replacement: String
    let matchField: RewriteMatchField
    let sampleTitle: String
    let sampleURL: String
    let expectedResult: String

    var id: String { name }

    static let all: [RegexExample] = [
        RegexExample(
            name: "Strip trailing site name",
            pattern: #"^(.*?)\s*[|·–—-]\s*[^|·–—-]+$"#,
            replacement: "$1",
            matchField: .title,
            sampleTitle: "How to Cook Rice | Bon Appétit",
            sampleURL: "https://bonappetit.com/rice",
            expectedResult: "How to Cook Rice"
        ),
        RegexExample(
            name: "Remove “ - YouTube”",
            pattern: #"^(.*?)\s*-\s*YouTube$"#,
            replacement: "$1",
            matchField: .title,
            sampleTitle: "Best Bass Solos Ever - YouTube",
            sampleURL: "https://youtube.com/watch?v=123",
            expectedResult: "Best Bass Solos Ever"
        ),
        RegexExample(
            name: "GitHub repo → breadcrumb",
            pattern: #"^https://github\.com/([^/]+)/([^/?#]+)$"#,
            replacement: "github > $1 > $2",
            matchField: .url,
            sampleTitle: "GitHub",
            sampleURL: "https://github.com/nvictor/maruko",
            expectedResult: "github > nvictor > maruko"
        ),
        RegexExample(
            name: "Title-case after a prefix",
            pattern: #"(?i)^article\s+(.+)$"#,
            replacement: "Article ${titlecase:1}",
            matchField: .title,
            sampleTitle: "article how to write punchlines",
            sampleURL: "https://example.com/punchlines",
            expectedResult: "Article How To Write Punchlines"
        ),
        RegexExample(
            name: "Delete bracketed tags",
            pattern: #"\s*\[[^\]]*\]"#,
            replacement: "",
            matchField: .title,
            sampleTitle: "Atalanta demo mix [WIP] [v3]",
            sampleURL: "https://example.com/atalanta",
            expectedResult: "Atalanta demo mix"
        ),
    ]
}
