import SwiftUI

struct RewriteRulesListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BookmarkStore

    @State private var selectedRuleID: UUID?
    @State private var showingAddRule = false
    @State private var editingRuleID: UUID?

    private var selectedRule: RewriteRule? {
        store.rewriteRules.first(where: { $0.id == selectedRuleID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rewrite Rules")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            List(selection: $selectedRuleID) {
                HStack {
                    Text("On").frame(width: 44, alignment: .leading)
                    Text("Name").frame(width: 180, alignment: .leading)
                    Text("Field").frame(width: 100, alignment: .leading)
                    Text("Pattern").frame(width: 240, alignment: .leading)
                    Text("Replacement").frame(width: 240, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(store.rewriteRules, id: \.id) { rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { store.setRewriteRuleEnabled(rule, isEnabled: $0) }
                        ))
                        .labelsHidden()
                        .frame(width: 44, alignment: .leading)

                        Text(rule.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 180, alignment: .leading)
                        Text(rule.matchField.rawValue)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 100, alignment: .leading)
                        Text(rule.pattern)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 240, alignment: .leading)
                        Text(rule.replacementTemplate)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 240, alignment: .leading)
                    }
                    .tag(rule.id)
                }
            }

            Divider()

            HStack {
                Button("Add Rule") { showingAddRule = true }

                Button("Edit Rule") {
                    editingRuleID = selectedRuleID
                }
                .disabled(selectedRule == nil)

                Button("Delete Rule", role: .destructive) {
                    if let selectedRule {
                        store.deleteRewriteRule(selectedRule)
                        selectedRuleID = nil
                    }
                }
                .disabled(selectedRule == nil)

                Spacer()

                Button("Move Up") {
                    if let selectedRule { store.moveRewriteRule(selectedRule, direction: -1) }
                }
                .disabled(!canMoveUp)

                Button("Move Down") {
                    if let selectedRule { store.moveRewriteRule(selectedRule, direction: 1) }
                }
                .disabled(!canMoveDown)
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 460)
        .onAppear {
            do {
                _ = try store.loadRewriteRules()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingAddRule) {
            RewriteRuleEditorView(
                title: "Add Rewrite Rule",
                initialDraft: RewriteRuleDraft(
                    name: "",
                    isEnabled: true,
                    order: store.rewriteRules.count,
                    matchField: .title,
                    pattern: "",
                    replacementTemplate: "",
                    isCaseSensitive: false
                )
            ) { draft in
                try store.addRewriteRule(from: draft)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingRuleID != nil },
            set: { if !$0 { editingRuleID = nil } }
        )) {
            if let rule = selectedRule {
                RewriteRuleEditorView(
                    title: "Edit Rewrite Rule",
                    initialDraft: RewriteRuleDraft(rule: rule)
                ) { draft in
                    try store.updateRewriteRule(rule, from: draft)
                }
            }
        }
    }

    private var canMoveUp: Bool {
        guard let selectedRule,
              let index = store.rewriteRules.firstIndex(where: { $0.id == selectedRule.id }) else {
            return false
        }
        return index > 0
    }

    private var canMoveDown: Bool {
        guard let selectedRule,
              let index = store.rewriteRules.firstIndex(where: { $0.id == selectedRule.id }) else {
            return false
        }
        return index < store.rewriteRules.count - 1
    }
}
