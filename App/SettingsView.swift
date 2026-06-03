import SwiftUI
import AppCore
import PRPilotModels

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AppearanceSettingsTab(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            DiscoverySettingsTab(model: model)
                .tabItem { Label("Discovery", systemImage: "magnifyingglass") }

            ToolsSettingsTab(model: model)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            ClaudeSettingsTab(model: model)
                .tabItem { Label("Claude", systemImage: "terminal") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct AppearanceSettingsTab: View {
    let model: AppModel

    @State private var appearance: Appearance = .system

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("\"System\" follows your macOS appearance setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appearance = model.settings.appearance
        }
        .onChange(of: appearance) { _, _ in commit() }
    }

    private func commit() {
        var updated = model.settings
        updated.appearance = appearance
        Task { await model.updateSettings(updated) }
    }
}

private struct DiscoverySettingsTab: View {
    let model: AppModel

    @State private var reviewRows: [QueryRow] = []
    @State private var myPRRows: [QueryRow] = []
    @State private var reviewEnabled = true
    @State private var myPRsEnabled = true
    @State private var pollIntervalSeconds = 120
    @State private var autoLoad = false

    private struct QueryRow: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var allowUnscoped: Bool
    }

    var body: some View {
        Form {
            Section("Auto load") {
                Toggle("Automatically start a Claude review for every PR", isOn: $autoLoad)
                Text("Reviews each PR at least once: resumes its session, or starts a fresh review for a new one. Runs at launch and when a PR is added (manually or via discovery). Repos without a local clone are reviewed when first opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            querySection(title: "Review requests", rows: $reviewRows, enabled: $reviewEnabled)
            querySection(title: "My PRs", rows: $myPRRows, enabled: $myPRsEnabled)

            if !model.discoveryWarnings.isEmpty {
                Section("Discovery warnings") {
                    ForEach(model.discoveryWarnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("Poll interval") {
                Stepper(value: $pollIntervalSeconds, in: 30...3600, step: 30) {
                    Text("\(pollIntervalSeconds) seconds")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reviewRows = model.settings.reviewRequestQueries.map { QueryRow(text: $0.text, allowUnscoped: $0.allowUnscoped) }
            myPRRows = model.settings.myPRQueries.map { QueryRow(text: $0.text, allowUnscoped: $0.allowUnscoped) }
            reviewEnabled = model.settings.reviewRequestsEnabled
            myPRsEnabled = model.settings.myPRsEnabled
            pollIntervalSeconds = model.settings.pollIntervalSeconds
            autoLoad = model.settings.autoLoad
        }
        .onChange(of: reviewRows) { _, _ in commit() }
        .onChange(of: myPRRows) { _, _ in commit() }
        .onChange(of: reviewEnabled) { _, _ in commit() }
        .onChange(of: myPRsEnabled) { _, _ in commit() }
        .onChange(of: pollIntervalSeconds) { _, _ in commit() }
        .onChange(of: autoLoad) { _, _ in commit() }
    }

    @ViewBuilder
    private func querySection(title: String, rows: Binding<[QueryRow]>, enabled: Binding<Bool>) -> some View {
        Section {
            Toggle("Enabled", isOn: enabled)
            ForEach(rows) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("gh search prs query", text: $row.text)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button(role: .destructive) {
                            rows.wrappedValue.removeAll { $0.id == row.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                    if !DiscoveryQuery.isScoped(row.text) && !row.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Not scoped to you, an org, or a repo — matches PRs across all of GitHub.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Run anyway", isOn: $row.allowUnscoped).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            Button {
                rows.wrappedValue.append(QueryRow(text: "", allowUnscoped: false))
            } label: { Label("Add query", systemImage: "plus") }
        } header: {
            Text(title)
        }
    }

    private func commit() {
        var updated = model.settings
        updated.reviewRequestQueries = reviewRows
            .map { DiscoveryQuery(text: $0.text.trimmingCharacters(in: .whitespaces), allowUnscoped: $0.allowUnscoped) }
            .filter { !$0.text.isEmpty }
        updated.myPRQueries = myPRRows
            .map { DiscoveryQuery(text: $0.text.trimmingCharacters(in: .whitespaces), allowUnscoped: $0.allowUnscoped) }
            .filter { !$0.text.isEmpty }
        updated.reviewRequestsEnabled = reviewEnabled
        updated.myPRsEnabled = myPRsEnabled
        updated.pollIntervalSeconds = pollIntervalSeconds
        updated.autoLoad = autoLoad
        Task { await model.updateSettings(updated) }
    }
}

private struct ToolsSettingsTab: View {
    let model: AppModel

    @State private var ghPath: String = ""
    @State private var gitPath: String = ""

    var body: some View {
        Form {
            Section("Tool paths") {
                pathRow(label: "gh", binding: $ghPath)
                pathRow(label: "git", binding: $gitPath)
                Text("Leave empty to auto-detect from your shell PATH — matches what `which gh` returns in your terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ghPath = model.settings.ghPath ?? ""
            gitPath = model.settings.gitPath ?? ""
        }
        .onChange(of: ghPath) { _, _ in commit() }
        .onChange(of: gitPath) { _, _ in commit() }
    }

    @ViewBuilder
    private func pathRow(label: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)
            Button("Choose…") {
                pickFile(into: binding)
            }
        }
    }

    private func pickFile(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func commit() {
        var updated = model.settings
        updated.ghPath = ghPath.isEmpty ? nil : ghPath
        updated.gitPath = gitPath.isEmpty ? nil : gitPath
        Task { await model.updateSettings(updated) }
    }
}

private struct ClaudeSettingsTab: View {
    let model: AppModel

    @State private var envText: String = ""
    @State private var claudePath: String = ""
    @State private var argsText: String = ""
    @State private var notificationsEnabled: Bool = true

    var body: some View {
        Form {
            Section("Extra environment variables for Claude Code") {
                TextField("", text: $envText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                Text("Prepended before the claude command, exactly as typed. Leave empty for none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code binary (uses PATH if not set)") {
                HStack {
                    TextField("", text: $claudePath)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                    Button("Choose…") { pickClaude() }
                }
            }

            Section("Claude arguments") {
                TextField("", text: $argsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                Text("Appended to the claude command, exactly as typed. The app then appends the /review command for the selected PR (or --resume to continue a session).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Send notification when a review goes idle", isOn: $notificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            envText = model.settings.claudeEnv
            claudePath = model.settings.claudePath ?? ""
            argsText = model.settings.claudeLaunchArgs
            notificationsEnabled = model.settings.notificationsEnabled
        }
        .onChange(of: envText) { _, _ in commit() }
        .onChange(of: claudePath) { _, _ in commit() }
        .onChange(of: argsText) { _, _ in commit() }
        .onChange(of: notificationsEnabled) { _, _ in commit() }
    }

    private func pickClaude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            claudePath = url.path
        }
    }

    private func commit() {
        var updated = model.settings
        updated.claudeEnv = envText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.claudePath = claudePath.isEmpty ? nil : claudePath
        updated.claudeLaunchArgs = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notificationsEnabled = notificationsEnabled
        Task { await model.updateSettings(updated) }
    }
}
