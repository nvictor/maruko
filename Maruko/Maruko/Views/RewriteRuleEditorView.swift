import SwiftUI

/// The rule-editing form, embedded in the right pane of the rules window.
/// The parent owns Save/Revert; this view edits the bound draft in place.
struct RewriteRuleFormView: View {
    @Binding var draft: RewriteRuleDraft

    @State private var sampleTitle = "How to Cook Rice | Bon Appétit"
    @State private var sampleURL = "https://bonappetit.com/rice"

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)

            regexFields

            Toggle("Enabled", isOn: $draft.isEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: - Regex kind

    @ViewBuilder
    private var regexFields: some View {
        Section {
            TextField("Regex Pattern", text: $draft.pattern)
                .font(.body.monospaced())
            TextField("Replacement (empty deletes the match)", text: $draft.replacementTemplate)
                .font(.body.monospaced())

            Picker("Match Field", selection: $draft.matchField) {
                Text("Title").tag(RewriteMatchField.title)
                Text("URL").tag(RewriteMatchField.url)
                Text("Title or URL").tag(RewriteMatchField.titleOrURL)
            }

            Toggle("Case Sensitive", isOn: $draft.isCaseSensitive)
        } header: {
            HStack {
                Text("Pattern")
                Spacer()
                Menu("Insert Example") {
                    ForEach(RegexExample.all) { example in
                        Button(example.name) {
                            insert(example)
                        }
                    }
                }
                .fixedSize()
            }
        }

        Section("Try It") {
            TextField("Sample title", text: $sampleTitle)
            if draft.matchField != .title {
                TextField("Sample URL", text: $sampleURL)
            }
            LabeledContent("Result") {
                previewResult
            }
        }

        Section {
            cheatSheet
        }
    }

    @ViewBuilder
    private var previewResult: some View {
        switch BookmarkRewriteEngine.validate(snapshot: draft.previewSnapshot(), name: "Preview") {
        case .invalid(let message):
            Text(message)
                .foregroundStyle(.red)
        case .valid:
            let rewritten = BookmarkRewriteEngine.rewrite(
                title: sampleTitle,
                url: sampleURL,
                snapshots: [draft.previewSnapshot()]
            )
            if rewritten == sampleTitle {
                Text("No match. Sample stays “\(sampleTitle)”")
                    .foregroundStyle(.secondary)
            } else {
                Text(rewritten)
                    .fontWeight(.medium)
            }
        }
    }

    private var cheatSheet: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Regex quick reference")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                cheatRow("( … )", "captures text you can reuse as $1, $2, …")
                cheatRow(".*", "any text (including nothing)")
                cheatRow(#"\s"#, "a space, tab, or line break")
                cheatRow("^ and $", "start and end of the text")
                cheatRow("(?i)", "put at the front to ignore letter case")
                cheatRow("${titlecase:1}", "Maruko extra: capture 1 in Title Case")
            }
            .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func cheatRow(_ token: String, _ meaning: String) -> some View {
        GridRow {
            Text(token)
                .font(.caption.monospaced())
            Text(meaning)
        }
    }

    private func insert(_ example: RegexExample) {
        draft.pattern = example.pattern
        draft.replacementTemplate = example.replacement
        draft.matchField = example.matchField
        draft.isCaseSensitive = false
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = example.name
        }
        sampleTitle = example.sampleTitle
        sampleURL = example.sampleURL
    }
}
