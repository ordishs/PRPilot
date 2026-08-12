import SwiftUI
import AppCore

@main
struct PRPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var showingManage = false
    @State private var webViewCache = WebViewCache()
    @State private var pruneCount: Int?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model, webViewCache: webViewCache)
                        .sheet(isPresented: $showingManage) {
                            ManageLocalClonesView(model: model, isPresented: $showingManage)
                        }
                        .confirmationDialog(
                            "Delete \(pruneCount ?? 0) orphaned worktree directories?",
                            isPresented: Binding(
                                get: { pruneCount != nil },
                                set: { if !$0 { pruneCount = nil } }
                            )
                        ) {
                            Button("Delete", role: .destructive) {
                                Task { await model.pruneOrphanedWorktrees() }
                                pruneCount = nil
                            }
                            Button("Cancel", role: .cancel) { pruneCount = nil }
                        } message: {
                            Text("This removes worktree checkouts no work item points at. Local commits in those directories are lost.")
                        }
                        .preferredColorScheme(model.settings.appearance.colorScheme)
                } else if let startupError {
                    Text(startupError)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    ProgressView().frame(minWidth: 900, minHeight: 600)
                }
            }
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    let created = try AppModelFactory.makeDefault()
                    created.webPreloadHandler = { review in
                        _ = webViewCache.ensure(for: review)
                    }
                    await created.load()
                    // Before anything opens a worktree. Deliberately not inside load(),
                    // which must not touch the filesystem outside the store.
                    await created.migrateWorktreeRoot()
                    created.startDiscoveryPolling()
                    created.prewarmClaude()
                    webViewCache.cap = created.settings.maxLiveWebViews
                    model = created
                    appDelegate.model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") {
                    guard let model else { return }
                    Task { await model.refreshAllNow() }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(model == nil)
            }
            CommandMenu("Repositories") {
                Button("Manage Local Clones…") {
                    showingManage = true
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(model == nil)

                Button("Prune Orphaned Worktrees…") {
                    guard let model else { return }
                    pruneCount = model.orphanedWorktreePaths().count
                }
                .disabled(model == nil)
            }
        }

        Settings {
            if let model {
                SettingsView(model: model)
                    .preferredColorScheme(model.settings.appearance.colorScheme)
            } else {
                Text("Loading…")
                    .frame(width: 540, height: 360)
            }
        }
    }
}
