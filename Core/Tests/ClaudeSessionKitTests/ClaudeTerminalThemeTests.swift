import Testing
import SwiftTerm
@testable import ClaudeSessionKit

@Test func lightAnsiPaletteHasSixteenColors() {
    #expect(ClaudeTerminalTheme.lightAnsiPalette.count == 16)
}

@Test func lightAnsiPaletteScalesChannelsTo16Bit() {
    // First entry is "normal black" 40,40,40 in 0–255 → ×257 in SwiftTerm's 0–65535 space.
    let black = ClaudeTerminalTheme.lightAnsiPalette[0]
    #expect(black.red == 40 * 257)
    #expect(black.green == 40 * 257)
    #expect(black.blue == 40 * 257)
}

@Test func darkAnsiPaletteHasSixteenColors() {
    #expect(ClaudeTerminalTheme.darkAnsiPalette.count == 16)
}
