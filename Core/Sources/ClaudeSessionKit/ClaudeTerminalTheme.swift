import AppKit
import SwiftTerm

/// Light-appearance colors for the Claude terminal. Dark appearance intentionally
/// uses SwiftTerm's built-in defaults (untouched), so this type only describes the
/// light theme and how to install it on a terminal view.
public enum ClaudeTerminalTheme {
    public static let lightBackground = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1)
    public static let lightForeground = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
    public static let lightCaret = NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1)
    public static let lightSelection = NSColor(srgbRed: 181 / 255, green: 213 / 255, blue: 255 / 255, alpha: 1)

    /// 16 ANSI colors tuned for a light background (normal 0–7, bright 8–15).
    public nonisolated(unsafe) static let lightAnsiPalette: [SwiftTerm.Color] = [
        color(40, 40, 40),    color(170, 30, 30),   color(30, 130, 40),   color(150, 110, 0),
        color(30, 80, 200),   color(150, 40, 150),  color(20, 120, 140),  color(90, 90, 90),
        color(90, 90, 90),    color(200, 40, 40),   color(40, 150, 50),   color(170, 120, 0),
        color(40, 90, 220),   color(170, 50, 170),  color(30, 140, 160),  color(30, 30, 30),
    ]

    /// Applies the light theme to a terminal view. Call before the process starts so
    /// Claude detects a light background on launch.
    @MainActor public static func applyLight(to view: LocalProcessTerminalView) {
        view.installColors(lightAnsiPalette)
        view.nativeBackgroundColor = lightBackground
        view.nativeForegroundColor = lightForeground
        view.caretColor = lightCaret
        view.selectedTextBackgroundColor = lightSelection
    }

    /// SwiftTerm `Color` uses 16-bit channels (0–65535); scale from 0–255 via ×257.
    private static func color(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}
