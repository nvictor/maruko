import SwiftUI

/// The Rewrite Rules window: rule list on the left, inline editor on the
/// right. Replaces the old fixed sheet (and its nested edit sheet).
struct RewriteRulesWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = RewriteRulesStore()

    @State private var selectedRuleID: UUID?
    @State private var draft: RewriteRuleDraft?
    @State private var isAddingNewRule = false
    @State private var validationError: String?

    private var selectedRule: RewriteRule? {
        store.rewriteRules.first { $0.id == selectedRuleID }
    }

    var body: some View {
        HSplitView {
            ruleList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
            editorPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onAppear {
            store.configure(context: modelContext)
            if selectedRuleID == nil {
                selectedRuleID = store.rewriteRules.first?.id
            }
        }
        .onChange(of: selectedRuleID) {
            isAddingNewRule = false
            validationError = nil
            draft = selectedRule.map { RewriteRuleDraft(rule: $0) }
        }
        .alert("Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Left pane

    private var ruleList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedRuleID) {
                ForEach(store.rewriteRules, id: \.id) { rule in
                    HStack(spacing: 8) {
                        Text(rule.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(rule.isEnabled ? .primary : .secondary)

                        Spacer()

                        if !rule.isEnabled {
                            Text("Off")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                                .foregroundStyle(.secondary)
                        }

                        Text(rule.kind == .aiPrompt ? "AI" : "Regex")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                    .tag(rule.id)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 12) {
                Button {
                    startAddingRule()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a rule")

                Button {
                    deleteSelectedRule()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedRule == nil)
                .help("Delete the selected rule")

                Spacer()

                Button {
                    if let selectedRule { store.moveRewriteRule(selectedRule, direction: -1) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMove(direction: -1))
                .help("Move up. Earlier rules run first")

                Button {
                    if let selectedRule { store.moveRewriteRule(selectedRule, direction: 1) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMove(direction: 1))
                .help("Move down")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: - Right pane

    @ViewBuilder
    private var editorPane: some View {
        if draft != nil {
            VStack(spacing: 0) {
                RewriteRuleFormView(draft: Binding(
                    get: { draft ?? .default },
                    set: { draft = $0 }
                ))

                Divider()

                HStack {
                    if let validationError {
                        Text(validationError)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(isAddingNewRule ? "Discard" : "Revert") {
                        revert()
                    }
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "No rule selected",
                systemImage: "wand.and.stars",
                description: Text("Select a rule to edit it, or click + to add one.")
            )
        }
    }

    // MARK: - Actions

    private func startAddingRule() {
        selectedRuleID = nil
        isAddingNewRule = true
        validationError = nil
        var newDraft = RewriteRuleDraft.default
        newDraft.name = ""
        newDraft.pattern = ""
        newDraft.replacementTemplate = ""
        newDraft.order = store.rewriteRules.count
        draft = newDraft
    }

    private func deleteSelectedRule() {
        guard let selectedRule else { return }
        store.deleteRewriteRule(selectedRule)
        selectedRuleID = store.rewriteRules.first?.id
    }

    private func save() {
        guard let draft else { return }
        do {
            if isAddingNewRule {
                try store.addRewriteRule(from: draft)
                isAddingNewRule = false
                selectedRuleID = store.rewriteRules.first { $0.name == draft.name }?.id
            } else if let selectedRule {
                try store.updateRewriteRule(selectedRule, from: draft)
            }
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func revert() {
        validationError = nil
        if isAddingNewRule {
            isAddingNewRule = false
            draft = nil
            selectedRuleID = store.rewriteRules.first?.id
        } else {
            draft = selectedRule.map { RewriteRuleDraft(rule: $0) }
        }
    }

    private func canMove(direction: Int) -> Bool {
        guard let selectedRule,
              let index = store.rewriteRules.firstIndex(where: { $0.id == selectedRule.id }) else {
            return false
        }
        return store.rewriteRules.indices.contains(index + direction)
    }
}
