import SwiftUI

struct BrowserProfileView: View {
    @ObservedObject var store: BrowserFormatStore
    @ObservedObject var rulesStore: RewriteRulesStore
    let profile: BrowserProfile

    @State private var showingApplyConfirmation = false
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let statusMessage = store.statusMessage {
                banner(statusMessage, systemImage: "checkmark.circle", tint: .green)
                Divider()
            }

            if let aiNotice = store.aiNotice {
                banner(aiNotice, systemImage: "sparkles", tint: .yellow)
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

            if store.bookmarkSyncEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("This profile syncs bookmarks, so \(profile.browser.displayName) would undo the format by restoring the old bookmarks from its sync server. Turn off bookmark sync for this profile, quit the browser, then Analyze again.")
                    Spacer()
                }
                .padding(10)
                .background(.orange.opacity(0.15))
                Divider()
            }

            content
        }
        .navigationTitle("\(profile.browser.displayName). \(profile.displayName)")
        .searchable(text: $filterText, placement: .toolbar, prompt: "Filter by title or URL")
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
                .disabled(store.plan == nil || store.plan?.isEmpty == true || store.browserIsRunning || store.bookmarkSyncEnabled || store.isWorking)

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
                Text("Removes \(plan.duplicates.count) duplicates, rewrites \(plan.titleChanges.count) titles, moves recently opened bookmarks up in \(plan.reorderedFolderCount) folders. A backup is created first.")
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
            if let progress = store.aiProgress, progress.total > 0 {
                VStack(spacing: 12) {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total)) {
                        Text("Rewriting titles with Apple Intelligence. \(progress.processed) of \(progress.total)…")
                    }
                    .frame(maxWidth: 420)

                    Button("Cancel") {
                        store.cancelAnalysis()
                    }
                }
            } else {
                ProgressView("Analyzing bookmarks…")
            }
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
        FormatPlanListView(
            plan: plan,
            filterText: filterText,
            recencyWindowDays: store.formatOptions.recencyWindowDays,
            lastFormattedAt: store.lastUndoRecord?.appliedAt
        )
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
        filterText = ""
        do {
            let snapshots = try rulesStore.enabledRuleSnapshots()
            await store.analyze(rules: snapshots)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
