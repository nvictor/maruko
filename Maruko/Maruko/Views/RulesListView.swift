import SwiftUI

struct RulesListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BookmarkStore

    @State private var selectedRuleID: UUID?
    @State private var showingAddRule = false
    @State private var editingRuleID: UUID?

    private var selectedRule: GroupingRule? {
        store.groupingRules.first(where: { $0.id == selectedRuleID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Grouping Rules")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            List(selection: $selectedRuleID) {
                HStack {
                    Text("On")
                        .frame(width: 44, alignment: .leading)
                    Text("Name")
                        .frame(minWidth: 120, alignment: .leading)
                    Text("Type")
                        .frame(width: 120, alignment: .leading)
                    Text("Pattern")
                        .frame(minWidth: 140, alignment: .leading)
                    Text("Target")
                        .frame(minWidth: 100, alignment: .leading)
                    Text("Order")
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(store.groupingRules, id: \.id) { rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { store.setRuleEnabled(rule, isEnabled: $0) }
                        ))
                        .labelsHidden()
                        .frame(width: 44, alignment: .leading)

                        Text(rule.name)
                            .frame(minWidth: 120, alignment: .leading)

                        Text(rule.kind.rawValue)
                            .frame(width: 120, alignment: .leading)

                        Text(rule.pattern)
                            .lineLimit(1)
                            .frame(minWidth: 140, alignment: .leading)

                        Text(rule.targetGroup)
                            .lineLimit(1)
                            .frame(minWidth: 100, alignment: .leading)

                        Text("\(rule.order)")
                            .frame(width: 60, alignment: .trailing)
                    }
                    .tag(rule.id)
                }
            }

            Divider()

            HStack {
                Button("Add Rule") {
                    showingAddRule = true
                }

                Button("Edit Rule") {
                    editingRuleID = selectedRuleID
                }
                .disabled(selectedRule == nil)

                Button("Delete Rule", role: .destructive) {
                    if let selectedRule {
                        store.deleteRule(selectedRule)
                        selectedRuleID = nil
                    }
                }
                .disabled(selectedRule == nil)

                Spacer()

                Button("Move Up") {
                    if let selectedRule {
                        store.moveRule(selectedRule, direction: -1)
                    }
                }
                .disabled(!canMoveUp)

                Button("Move Down") {
                    if let selectedRule {
                        store.moveRule(selectedRule, direction: 1)
                    }
                }
                .disabled(!canMoveDown)
            }
            .padding()
        }
        .frame(minWidth: 780, minHeight: 460)
        .onAppear {
            do {
                _ = try store.loadRules()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingAddRule) {
            RuleEditorView(
                title: "Add Rule",
                initialDraft: GroupingRuleDraft(
                    name: "",
                    isEnabled: true,
                    order: store.groupingRules.count,
                    kind: .containsText,
                    pattern: "",
                    targetGroup: "Ungrouped",
                    matchField: .title,
                    isCaseSensitive: false
                )
            ) { draft in
                try store.addRule(from: draft)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingRuleID != nil },
            set: { if !$0 { editingRuleID = nil } }
        )) {
            if let rule = selectedRule {
                RuleEditorView(
                    title: "Edit Rule",
                    initialDraft: GroupingRuleDraft(rule: rule)
                ) { draft in
                    try store.updateRule(rule, from: draft)
                }
            }
        }
    }

    private var canMoveUp: Bool {
        guard let selectedRule,
              let index = store.groupingRules.firstIndex(where: { $0.id == selectedRule.id }) else {
            return false
        }
        return index > 0
    }

    private var canMoveDown: Bool {
        guard let selectedRule,
              let index = store.groupingRules.firstIndex(where: { $0.id == selectedRule.id }) else {
            return false
        }
        return index < store.groupingRules.count - 1
    }
}
