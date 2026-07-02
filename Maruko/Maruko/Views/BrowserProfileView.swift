import SwiftUI

struct BrowserProfileView: View {
    @ObservedObject var store: BrowserFormatStore
    @ObservedObject var rulesStore: RewriteRulesStore
    let profile: BrowserProfile

    @State private var showingApplyConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if let statusMessage = store.statusMessage {
                banner(statusMessage, systemImage: "checkmark.circle", tint: .green)
                Divider()
            }

            if store.browserIsRunning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(profile.browser.displayName) is running. Quit it to format bookmarks.")
                    Spacer()
                    Button("Recheck") {
                        store.recheckBrowserRunning()
                    }
                }
                .padding(10)
                .background(.yellow.opacity(0.15))
                Divider()
            }

            content
        }
        .navigationTitle("\(profile.browser.displayName) — \(profile.displayName)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Remove Duplicates", isOn: $store.formatOptions.removeDuplicates)
                    Toggle("Rewrite Titles", isOn: $store.formatOptions.rewriteTitles)
                    Toggle("Move Recently Opened to Top", isOn: $store.formatOptions.moveRecentToTop)
                    Picker("Recently Opened Means", selection: $store.formatOptions.recencyWindowDays) {
                        ForEach(FormatOptions.recencyWindowChoices, id: \.self) { days in
                            Text("Last \(days) days").tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!store.formatOptions.moveRecentToTop)
                } label: {
                    Label("Format Options", systemImage: "slider.horizontal.3")
                }
                .disabled(store.isWorking)
                .help("Choose what Format Bookmarks does")

                Button("Analyze") {
                    Task { await analyze() }
                }
                .disabled(store.isWorking)

                Button("Format Bookmarks") {
                    showingApplyConfirmation = true
                }
                .disabled(store.plan == nil || store.plan?.isEmpty == true || store.browserIsRunning || store.isWorking)

                Button("Undo Last Change") {
                    store.undoLastChange()
                }
                .disabled(store.lastUndoRecord == nil || store.browserIsRunning || store.isWorking)
            }
        }
        .confirmationDialog(
            "Format \(profile.browser.displayName) bookmarks?",
            isPresented: $showingApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Format Bookmarks") {
                store.apply()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let plan = store.plan {
                Text("Removes \(plan.duplicates.count) duplicates, rewrites \(plan.titleChanges.count) titles, moves recently opened bookmarks up in \(plan.reorderedFolderCount) folders. A backup is created first. If browser sync is enabled, changes propagate on next launch.")
            }
        }
        .task(id: profile) {
            await analyze()
        }
        .onChange(of: store.formatOptions) {
            Task { await analyze() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isWorking {
            Spacer()
            ProgressView("Analyzing bookmarks…")
            Spacer()
        } else if let plan = store.plan {
            planView(plan)
        } else {
            Spacer()
            ContentUnavailableView(
                "Not analyzed yet",
                systemImage: "sparkles",
                description: Text("Click Analyze to preview what Format Bookmarks would change.")
            )
            Spacer()
        }
    }

    private func planView(_ plan: FormatPlan) -> some View {
        List {
            Section("Overview") {
                LabeledContent("Bookmarks", value: "\(plan.totalBookmarks)")
                LabeledContent("Folders", value: "\(plan.totalFolders)")
                if let record = store.lastUndoRecord {
                    LabeledContent("Last formatted", value: record.appliedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if plan.isEmpty {
                    Label("Already clean — nothing to change.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }

            if !plan.duplicates.isEmpty {
                Section("Duplicates to remove (\(plan.duplicates.count))") {
                    ForEach(plan.duplicates) { duplicate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(duplicate.title.isEmpty ? duplicate.url : duplicate.title)
                                .lineLimit(1)
                            Text("\(duplicate.folderPath) — kept in \(duplicate.keptFolderPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if !plan.titleChanges.isEmpty {
                Section("Titles to rewrite (\(plan.titleChanges.count))") {
                    ForEach(plan.titleChanges) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.oldTitle)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(change.newTitle)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if plan.reorderedFolderCount > 0 {
                Section("Recently Opened") {
                    Label(
                        "\(plan.reorderedFolderCount) folders will have bookmarks opened in the last \(store.formatOptions.recencyWindowDays) days moved to the top. The bookmark bar's own row is never reordered.",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
            Spacer()
            Button {
                store.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(tint.opacity(0.12))
    }

    private func analyze() async {
        do {
            let snapshots = try rulesStore.enabledRuleSnapshots()
            await store.analyze(rules: snapshots)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
