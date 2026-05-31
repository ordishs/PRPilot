import SwiftUI
import AppCore
import PRPilotModels

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
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

private struct DiscoverySettingsTab: View {
    let model: AppModel

    @State private var queriesText: String = ""
    @State private var pollIntervalSeconds: Int = 120
    @State private var autoLoad: Bool = false

    var body: some View {
        Form {
            Section("Auto load") {
                Toggle("Automatically start a Claude review for every PR", isOn: $autoLoad)
                Text("Reviews each PR at least once: resumes its session, or starts a fresh review for a new one. Runs at launch and when a PR is added (manually or via discovery). Repos without a local clone are reviewed when first opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Search queries (one per line)") {
                TextEditor(text: $queriesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .border(Color.secondary.opacity(0.3))
                Text("Each line is a separate `gh search prs` query. Include `is:open` to filter out closed PRs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Poll interval") {
                Stepper(value: $pollIntervalSeconds, in: 30...3600, step: 30) {
                    Text("\(pollIntervalSeconds) seconds")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            queriesText = model.settings.discoveryQueries.joined(separator: "\n")
            pollIntervalSeconds = model.settings.pollIntervalSeconds
            autoLoad = model.settings.autoLoad
        }
        .onChange(of: queriesText) { _, newValue in commit() }
        .onChange(of: pollIntervalSeconds) { _, _ in commit() }
        .onChange(of: autoLoad) { _, _ in commit() }
    }

    private func commit() {
        let lines = queriesText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var updated = model.settings
        updated.discoveryQueries = lines
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
