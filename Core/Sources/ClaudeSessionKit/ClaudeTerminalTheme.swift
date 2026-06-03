import AppKit
import SwiftTerm

/// Explicit light and dark color themes for the Claude terminal. Both are applied
/// directly to the terminal view so the chrome (background/foreground/cursor/selection
/// and the 16 ANSI colors) deterministically follows the app appearance — we never rely
/// on SwiftTerm's defaults or on a relaunch to change the colors.
public enum ClaudeTerminalTheme {
    // MARK: Light

    public static let lightBackground = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1)
    public static let lightForeground = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
    public static let lightCaret = NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1)
    public static let lightSelection = NSColor(srgbRed: 181 / 255, green: 213 / 255, blue: 255 / 255, alpha: 1)

    /// 16 ANSI colors tuned for a light background (normal 0–7, bright 8–15).
    public nonisolated(unsafe) static let lightAnsiPalette: [SwiftTerm.Color] = [
        color(40, 40, 40),    color(190, 30, 30),   color(20, 130, 40),   color(150, 100, 0),
        color(20, 80, 210),   color(160, 40, 160),  color(10, 120, 140),  color(90, 90, 90),
        color(90, 90, 90),    color(220, 40, 40),   color(30, 150, 50),   color(170, 115, 0),
        color(30, 90, 230),   color(180, 50, 180),  color(20, 140, 160),  color(20, 20, 20),
    ]

    // MARK: Dark

    public static let darkBackground = NSColor(srgbRed: 22 / 255, green: 23 / 255, blue: 27 / 255, alpha: 1)
    public static let darkForeground = NSColor(srgbRed: 228 / 255, green: 228 / 255, blue: 233 / 255, alpha: 1)
    public static let darkCaret = NSColor(srgbRed: 225 / 255, green: 225 / 255, blue: 230 / 255, alpha: 1)
    public static let darkSelection = NSColor(srgbRed: 60 / 255, green: 92 / 255, blue: 150 / 255, alpha: 1)

    /// 16 ANSI colors tuned for a dark background (normal 0–7, bright 8–15) — vivid and
    /// distinct so syntax/diagnostic colors read clearly.
    public nonisolated(unsafe) static let darkAnsiPalette: [SwiftTerm.Color] = [
        color(70, 70, 78),    color(255, 95, 90),   color(95, 220, 120),  color(240, 200, 90),
        color(110, 160, 255), color(220, 130, 255), color(90, 215, 230),  color(200, 200, 208),
        color(120, 120, 128), color(255, 130, 125), color(130, 240, 150), color(255, 220, 120),
        color(140, 185, 255), color(235, 160, 255), color(130, 230, 245), color(245, 245, 250),
    ]

    // MARK: Apply

    /// Applies the theme for the given appearance to a terminal view. When changing an
    /// already-running terminal this updates its chrome immediately; when called before
    /// `start()` it also lets Claude detect the background on launch.
    @MainActor public static func apply(isDark: Bool, to view: LocalProcessTerminalView) {
        view.installColors(isDark ? darkAnsiPalette : lightAnsiPalette)
        view.nativeBackgroundColor = isDark ? darkBackground : lightBackground
        view.nativeForegroundColor = isDark ? darkForeground : lightForeground
        view.caretColor = isDark ? darkCaret : lightCaret
        view.selectedTextBackgroundColor = isDark ? darkSelection : lightSelection
    }

    /// SwiftTerm `Color` uses 16-bit channels (0–65535); scale from 0–255 via ×257.
    private static func color(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}
