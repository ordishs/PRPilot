import SwiftUI
import AppCore

@main
struct PRReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var showingManage = false
    @State private var webViewCache = WebViewCache()

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model, webViewCache: webViewCache)
                        .sheet(isPresented: $showingManage) {
                            ManageLocalClonesView(model: model, isPresented: $showingManage)
                        }
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
                    created.startDiscoveryPolling()
                    created.prewarmDiffs()
                    created.prewarmClaude()
                    for review in created.reviews where !review.disabled {
                        _ = webViewCache.ensure(for: review)
                    }
                    model = created
                    appDelegate.model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
        }
        .commands {
            CommandMenu("Repositories") {
                Button("Manage Local Clones…") {
                    showingManage = true
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(model == nil)
            }
        }

        Settings {
            if let model {
                SettingsView(model: model)
            } else {
                Text("Loading…")
                    .frame(width: 540, height: 360)
            }
        }
    }
}
