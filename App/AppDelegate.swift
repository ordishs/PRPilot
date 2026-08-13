import AppKit
import AppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftTerm forces context.setShouldSmoothFonts(true), which applies macOS
        // font smoothing (stem-darkening) and makes terminal glyphs look heavy/fuzzy
        // versus the crisp system UI. Disabling CG font smoothing for our process
        // overrides it, so text renders sharp like the rest of macOS.
        UserDefaults.standard.set(true, forKey: "CGFontRenderingFontSmoothingDisabled")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.terminateAllAgentSessions()
    }
}
