import SwiftUI

/// Detail view for the extension-format flow: guides the one-time install,
/// shows the pairing code, previews the plan a connected extension sends,
/// and hands the confirmed ops back for it to apply. Works with Chrome
/// running and Sync on. The extension applies every edit through
/// chrome.bookmarks, so sync journals them like ordinary edits.
struct ChromeExtensionView: View {
    @ObservedObject var extensionStore: ExtensionFormatStore

    @State private var showingApplyConfirmation = false
    @State private var setupExpanded = false
    @State private var filterText = ""

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let statusMessage = extensionStore.statusMessage {
                    banner(statusMessage, systemImage: "checkmark.circle", tint: .green) {
                        extensionStore.statusMessage = nil
                    }
                    Divider()
                }

                if let aiNotice = extensionStore.aiNotice {
                    banner(aiNotice, systemImage: "sparkles", tint: .yellow)
                    Divider()
                }

                setupSection
                Divider()

                content
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .navigationTitle("Chrome Extension")
        .searchable(text: $filterText, placement: .toolbar, prompt: "Filter by title or URL")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Remove Duplicates", isOn: $extensionStore.formatOptions.removeDuplicates)
                    Toggle("Rewrite Titles", isOn: $extensionStore.formatOptions.rewriteTitles)
                    Toggle("Move Recently Opened to Top", isOn: $extensionStore.formatOptions.moveRecentToTop)
                    Picker("Recently Opened Means", selection: $extensionStore.formatOptions.recencyWindowDays) {
                        ForEach(FormatOptions.recencyWindowChoices, id: \.self) { days in
                            Text("Last \(days) days").tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!extensionStore.formatOptions.moveRecentToTop)
                } label: {
                    Label("Format Options", systemImage: "slider.horizontal.3")
                }
                .disabled(extensionStore.phase == .analyzing)
                .help("Choose what Format Bookmarks does")

                Button("Sort Recent Folder") {
                    extensionStore.sortRecentFolder()
                }
                .disabled(extensionStore.phase != .awaitingConfirmation)
                .help("Sorts the \u{201C}Recent\u{201D} folder by last opened, pulls in newly-visited bookmarks from Other Bookmarks, and keeps only the 20 most recent. Independent of Format Bookmarks.")

                Button("Apply via Extension") {
                    showingApplyConfirmation = true
                }
                .disabled(extensionStore.phase != .awaitingConfirmation || extensionStore.plan?.isEmpty == true)
            }
        }
        .confirmationDialog(
            "Apply the formatting through the Chrome extension?",
            isPresented: $showingApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply via Extension") {
                extensionStore.confirm()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let plan = extensionStore.plan {
                Text(plan.confirmationSummary)
            }
        }
        .task {
            extensionStore.start()
            extensionStore.refreshInstallState()
            setupExpanded = !extensionStore.extensionConnected
        }
        .onChange(of: extensionStore.extensionConnected) { _, connected in
            if connected { setupExpanded = false }
        }
    }

    // MARK: - Setup / pairing

    private var setupSection: some View {
        DisclosureGroup(isExpanded: $setupExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                setupStep(1, "Click Install Extension to put the extension where Chrome can load it. Finder opens with the folder selected.") {
                    Button("Install Extension…") {
                        extensionStore.installExtension()
                    }
                    Button("Export to Folder…") {
                        extensionStore.exportToChosenFolder()
                    }
                    .controlSize(.small)
                }
                setupStep(2, "In Chrome, open chrome://extensions and switch on Developer mode (top right).") {
                    Button("Copy chrome://extensions") {
                        extensionStore.copyToPasteboard("chrome://extensions")
                    }
                }
                setupStep(3, "Drag the ChromeExtension folder from Finder onto the extensions page (or use Load unpacked).", buttons: {})
                setupStep(4, "Click the Maruko icon in Chrome's toolbar and paste the pairing code.") {
                    if let code = extensionStore.pairingCode {
                        Text(code)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button("Copy") {
                            extensionStore.copyToPasteboard(code)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: extensionStore.extensionConnected ? "checkmark.circle.fill" : "puzzlepiece.extension")
                    .foregroundStyle(extensionStore.extensionConnected ? .green : .secondary)
                Text(extensionStore.extensionConnected ? "Extension connected" : "Set up the Chrome extension")
                Spacer()
                serverStatus
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch extensionStore.serverState {
        case .stopped, .starting:
            Text("Starting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .listening(let port):
            Text("Listening on 127.0.0.1:\(String(port))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func setupStep(
        _ number: Int,
        _ text: String,
        @ViewBuilder buttons: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
            buttons()
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch extensionStore.phase {
        case .waitingForSession:
            Spacer()
            ContentUnavailableView(
                "Waiting for Chrome",
                systemImage: "arrow.down.circle.dotted",
                description: Text("Click the Maruko icon in Chrome's toolbar and press Send Bookmarks to analyze this profile.")
            )
            Spacer()
        case .analyzing:
            Spacer()
            if let progress = extensionStore.aiProgress, progress.total > 0 {
                VStack(spacing: 12) {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total)) {
                        Text("Rewriting titles with Apple Intelligence. \(progress.processed) of \(progress.total)…")
                    }
                    .frame(maxWidth: 420)

                    Button("Cancel") {
                        extensionStore.cancelAnalysis()
                    }
                }
            } else {
                ProgressView("Analyzing bookmarks…")
            }
            Spacer()
        case .awaitingConfirmation:
            if let plan = extensionStore.plan {
                FormatPlanListView(
                    plan: plan,
                    filterText: filterText,
                    recencyWindowDays: extensionStore.formatOptions.recencyWindowDays,
                    lastFormattedAt: nil
                )
            }
        case .waitingForExtension:
            Spacer()
            ContentUnavailableView(
                "Waiting for the extension",
                systemImage: "puzzlepiece.extension",
                description: Text("The extension applies the changes on its next poll. If you closed the popup, click the Maruko icon in Chrome to resume.")
            )
            Spacer()
        case .applied:
            Spacer()
            ContentUnavailableView {
                Label("Bookmarks formatted", systemImage: "checkmark.seal")
            } description: {
                Text(extensionStore.resultSummary ?? "The extension applied all changes.")
            } actions: {
                Text("To format again, press Send Bookmarks in the extension popup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        case .failed:
            Spacer()
            ContentUnavailableView {
                Label("Formatting failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(extensionStore.resultSummary ?? extensionStore.errorMessage ?? "Something went wrong. Send the bookmarks again from the extension popup.")
            }
            Spacer()
        }
    }

    private func banner(
        _ text: String,
        systemImage: String,
        tint: Color,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
            Spacer()
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(tint.opacity(0.12))
    }
}
