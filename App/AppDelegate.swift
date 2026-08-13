import AppKit
import AppCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    private var quitWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftTerm forces context.setShouldSmoothFonts(true), which applies macOS
        // font smoothing (stem-darkening) and makes terminal glyphs look heavy/fuzzy
        // versus the crisp system UI. Disabling CG font smoothing for our process
        // overrides it, so text renders sharp like the rest of macOS.
        UserDefaults.standard.set(true, forKey: "CGFontRenderingFontSmoothingDisabled")
    }

    /// Holds the quit open until every agent process is gone.
    ///
    /// `applicationWillTerminate` cannot do this work. It is synchronous, and AppKit exits the
    /// process the moment it returns, so the escalation from `SIGTERM` to `SIGKILL` never runs and
    /// anything that ignored the first signal survives the quit. `.terminateLater` is the only
    /// point in the quit sequence that can wait for an async result.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasLiveAgentSessions else { return .terminateNow }

        let progress = model.beginShutdown()
        presentQuitWindow(for: progress)

        Task { @MainActor in
            await model.shutdownAgentSessions()
            dismissQuitWindow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A backstop for the paths that skip `applicationShouldTerminate`, such as a logout that
    /// AppKit drives itself. It cannot wait, so it is strictly less thorough than the quit above.
    func applicationWillTerminate(_ notification: Notification) {
        model?.terminateAllAgentSessions()
    }

    /// A floating panel, because the main window closes before the quit reaches this point and
    /// the wait would otherwise happen behind whatever app is underneath.
    private func presentQuitWindow(for progress: ShutdownProgress) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.contentView = NSHostingView(rootView: QuitProgressView(progress: progress))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        quitWindow = window
    }

    private func dismissQuitWindow() {
        quitWindow?.orderOut(nil)
        quitWindow = nil
    }
}
