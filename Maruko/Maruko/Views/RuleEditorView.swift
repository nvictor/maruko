import SwiftUI

struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialDraft: GroupingRuleDraft
    let onSave: (GroupingRuleDraft) throws -> Void

    @State private var draft: GroupingRuleDraft
    @State private var validationError: String?

    init(title: String, initialDraft: GroupingRuleDraft, onSave: @escaping (GroupingRuleDraft) throws -> Void) {
        self.title = title
        self.initialDraft = initialDraft
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: $draft.name)

                Picker("Rule Type", selection: $draft.kind) {
                    Text("Contains Text").tag(RuleKind.containsText)
                    Text("Regex").tag(RuleKind.regex)
                    Text("Domain").tag(RuleKind.domain)
                }

                TextField(patternLabel, text: $draft.pattern)

                if draft.kind != .domain {
                    Picker("Match Field", selection: $draft.matchField) {
                        Text("Title").tag(MatchField.title)
                        Text("URL").tag(MatchField.url)
                        Text("Title or URL").tag(MatchField.titleOrURL)
                    }
                }

                if draft.kind != .domain {
                    Toggle("Case Sensitive", isOn: $draft.isCaseSensitive)
                }

                TextField("Target Group", text: $draft.targetGroup)
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

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 360)
        .navigationTitle(title)
    }

    private var patternLabel: String {
        switch draft.kind {
        case .containsText:
            return "Text Pattern"
        case .regex:
            return "Regex Pattern"
        case .domain:
            return "Domain Pattern"
        }
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
