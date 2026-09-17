import AppKit
import AppCore
import GatewayKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    private var quitWindow: NSWindow?
    private var gateway: GatewayService?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftTerm forces context.setShouldSmoothFonts(true), which applies macOS
        // font smoothing (stem-darkening) and makes terminal glyphs look heavy/fuzzy
        // versus the crisp system UI. Disabling CG font smoothing for our process
        // overrides it, so text renders sharp like the rest of macOS.
        UserDefaults.standard.set(true, forKey: "CGFontRenderingFontSmoothingDisabled")
    }

    /// Starts or stops the gateway to match Settings. Called once the model has loaded and
    /// again whenever the user changes the toggle or the port.
    func reconcileGateway(model: AppModel) {
        let wanted = model.settings.gatewayEnabled
        let host = TailnetAddress.bindAddress(for: model.settings.gatewayBindScope)
        let addressChanged = gateway?.port != model.settings.gatewayPort || gateway?.host != host

        if wanted, gateway == nil || addressChanged {
            gateway?.stop()
            let service = GatewayService(
                backend: model,
                host: host,
                port: model.settings.gatewayPort,
                token: GatewayToken.loadOrCreate(),
                appVersion: Self.shortVersion,
                webRoot: Self.bundledWebRoot()
            )
            service.start()
            gateway = service
        } else if !wanted, gateway != nil {
            gateway?.stop()
            gateway = nil
        }
    }

    /// Where a reverse proxy should point, shown in Settings. Nil when the gateway is off.
    var gatewayProxyTarget: String? { gateway?.proxyTarget }

    /// The bundled client, when it is present. A build without it still serves the API, so
    /// the gateway is useful from `curl` before the web client exists.
    private static func bundledWebRoot() -> URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
              FileManager.default.fileExists(atPath: root.path)
        else {
            return nil
        }
        return root
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Holds the quit open until every agent process is gone.
    ///
    /// `applicationWillTerminate` cannot do this work. It is synchronous, and AppKit exits the
    /// process the moment it returns, so the escalation from `SIGTERM` to `SIGKILL` never runs and
    /// anything that ignored the first signal survives the quit. `.terminateLater` is the only
    /// point in the quit sequence that can wait for an async result.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        gateway?.stop()
        gateway = nil

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
        gateway?.stop()
        gateway = nil
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
