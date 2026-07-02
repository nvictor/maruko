import SwiftUI

struct RewriteRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialDraft: RewriteRuleDraft
    let onSave: (RewriteRuleDraft) throws -> Void

    @State private var draft: RewriteRuleDraft
    @State private var validationError: String?

    init(title: String, initialDraft: RewriteRuleDraft, onSave: @escaping (RewriteRuleDraft) throws -> Void) {
        self.title = title
        self.initialDraft = initialDraft
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: $draft.name)

                Picker("Kind", selection: $draft.kind) {
                    ForEach(RewriteRuleKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                switch draft.kind {
                case .regexMatchReplace:
                    TextField("Regex Pattern", text: $draft.pattern)
                    TextField("Replacement", text: $draft.replacementTemplate)

                    Picker("Match Field", selection: $draft.matchField) {
                        Text("Title").tag(RewriteMatchField.title)
                        Text("URL").tag(RewriteMatchField.url)
                        Text("Title or URL").tag(RewriteMatchField.titleOrURL)
                    }

                    Toggle("Case Sensitive", isOn: $draft.isCaseSensitive)

                case .aiPrompt:
                    Section {
                        TextEditor(text: $draft.replacementTemplate)
                            .font(.body)
                            .frame(minHeight: 96)
                    } header: {
                        Text("Instructions")
                    } footer: {
                        Text("Plain-language rules for the on-device model, e.g. \"Remove trailing site names and use sentence case.\" Applies only to recently opened bookmarks.")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Enabled", isOn: $draft.isEnabled)
            }
            .formStyle(.grouped)

            if let validationError {
                Text(validationError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
        .navigationTitle(title)
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
