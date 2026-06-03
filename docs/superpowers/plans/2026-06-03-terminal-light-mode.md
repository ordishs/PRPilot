# Claude Terminal Light Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Claude review terminal follow System / Light / Dark, relaunching only the currently-selected session (resuming) on a scheme change so Claude re-detects the background.

**Architecture:** A new `ClaudeTerminalTheme` (ClaudeSessionKit) holds a light palette and applies it to a `LocalProcessTerminalView`. `ClaudeSession` exposes `applyLightAppearance()`. `AppModel` tracks `terminalIsDark`, themes freshly-created sessions before `start()`, and `setTerminalAppearance(isDark:)` relaunches the selected resumable session. `ContentView` observes the effective `@Environment(\.colorScheme)` and feeds it to the model. Dark mode is the untouched SwiftTerm default (zero regression).

**Tech Stack:** Swift 6, SwiftUI, AppKit, SwiftTerm 1.13.0, swift-testing. Model tests: `cd Core && swift test`. App build: `xcodegen generate && xcodebuild ...`.

**Reference spec:** `docs/superpowers/specs/2026-06-03-terminal-light-mode-design.md`

---

## File Structure

- **Create** `Core/Sources/ClaudeSessionKit/ClaudeTerminalTheme.swift` — light palette + `applyLight(to:)`.
- **Modify** `Core/Sources/ClaudeSessionKit/ClaudeSession.swift` — add `applyLightAppearance()`.
- **Create** `Core/Tests/ClaudeSessionKitTests/ClaudeTerminalThemeTests.swift` — palette shape/conversion tests.
- **Modify** `Core/Sources/AppCore/AppModel.swift` — `terminalIsDark`, theme-on-create, `setTerminalAppearance(isDark:)`, seed from settings in `load()`.
- **Modify** `Core/Tests/AppCoreTests/AppModelTests.swift` — `setTerminalAppearance` guard test.
- **Modify** `App/ContentView.swift` — observe effective `colorScheme`, feed the model.

---

## Task 7: `ClaudeTerminalTheme` + `ClaudeSession.applyLightAppearance()` (ClaudeSessionKit, TDD)

**Files:**
- Create: `Core/Sources/ClaudeSessionKit/ClaudeTerminalTheme.swift`
- Modify: `Core/Sources/ClaudeSessionKit/ClaudeSession.swift`
- Test: `Core/Tests/ClaudeSessionKitTests/ClaudeTerminalThemeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/ClaudeSessionKitTests/ClaudeTerminalThemeTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter lightAnsi`
Expected: FAIL — `ClaudeTerminalTheme` does not exist.

- [ ] **Step 3: Create `ClaudeTerminalTheme`**

Create `Core/Sources/ClaudeSessionKit/ClaudeTerminalTheme.swift`:

```swift
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
    public static let lightAnsiPalette: [SwiftTerm.Color] = [
        color(40, 40, 40),    color(170, 30, 30),   color(30, 130, 40),   color(150, 110, 0),
        color(30, 80, 200),   color(150, 40, 150),  color(20, 120, 140),  color(90, 90, 90),
        color(90, 90, 90),    color(200, 40, 40),   color(40, 150, 50),   color(170, 120, 0),
        color(40, 90, 220),   color(170, 50, 170),  color(30, 140, 160),  color(30, 30, 30),
    ]

    /// Applies the light theme to a terminal view. Call before the process starts so
    /// Claude detects a light background on launch.
    public static func applyLight(to view: LocalProcessTerminalView) {
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
```

- [ ] **Step 4: Add `applyLightAppearance()` to `ClaudeSession`**

In `Core/Sources/ClaudeSessionKit/ClaudeSession.swift`, add this method inside the
`ClaudeSession` class (e.g. right after `public func start()`'s closing brace, before
`restart()`):

```swift
    /// Applies the light terminal theme. Dark appearance needs no call — the terminal
    /// uses SwiftTerm's defaults. Call before `start()` so Claude detects the background.
    public func applyLightAppearance() {
        ClaudeTerminalTheme.applyLight(to: terminalView)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter lightAnsi`
Expected: PASS — both tests green.

- [ ] **Step 6: Run the ClaudeSessionKit suite for regressions**

Run: `cd Core && swift test --filter ClaudeSessionKitTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/ClaudeSessionKit/ClaudeTerminalTheme.swift Core/Sources/ClaudeSessionKit/ClaudeSession.swift Core/Tests/ClaudeSessionKitTests/ClaudeTerminalThemeTests.swift
git commit -m "feat(terminal): add light terminal theme" --no-verify
```

---

## Task 8: `AppModel` appearance state + relaunch (AppCore, TDD)

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift` (add property; theme-on-create at line ~507–510; add `setTerminalAppearance`; seed in `load()`)
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Core/Tests/AppCoreTests/AppModelTests.swift` (append a new test; reuse the existing stub-construction pattern already used throughout the file):

```swift
@Test @MainActor func setTerminalAppearanceFlipsOnlyOnChange() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    #expect(model.terminalIsDark == true)
    await model.setTerminalAppearance(isDark: true)   // no-op
    #expect(model.terminalIsDark == true)
    await model.setTerminalAppearance(isDark: false)  // flips; no selection → no relaunch
    #expect(model.terminalIsDark == false)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Core && swift test --filter setTerminalAppearanceFlipsOnlyOnChange`
Expected: FAIL — `terminalIsDark` / `setTerminalAppearance` do not exist.

- [ ] **Step 3: Add the `terminalIsDark` property**

In `Core/Sources/AppCore/AppModel.swift`, add near the other published session state
(just after `public private(set) var claudePaneState: [String: ClaudePaneState] = [:]`,
line ~28):

```swift
    public private(set) var terminalIsDark: Bool = true
```

- [ ] **Step 4: Theme freshly-created sessions before start()**

In `ensureClaudeSession`, between `let session = ClaudeSession(spec: spec)` and
`session.start()` (lines ~507–510), insert the theme application:

```swift
        let session = ClaudeSession(spec: spec)
        claudeSessions[review.id] = session
        claudePaneState[review.id] = .sessionLive
        if !terminalIsDark {
            session.applyLightAppearance()
        }
        session.start()
```

- [ ] **Step 5: Add `setTerminalAppearance(isDark:)`**

In `Core/Sources/AppCore/AppModel.swift`, add this method (place it near the other
public session methods, e.g. after `clearClaudeSession(for:)`):

```swift
    /// Updates the terminal appearance. On a real change, relaunches ONLY the currently
    /// selected session (resuming) so Claude re-detects the background and re-themes its
    /// TUI. Other running sessions are left as-is (see spec: selected-only scope). The
    /// selected session is relaunched only if it is safely resumable.
    public func setTerminalAppearance(isDark: Bool) async {
        guard isDark != terminalIsDark else { return }
        terminalIsDark = isDark

        guard let id = selection,
              claudeSessions[id] != nil,
              let review = reviews.first(where: { $0.id == id }),
              let worktreePath = review.worktreePath,
              let sessionID = review.claudeSessionID,
              ClaudeTranscriptPath.transcriptExists(forWorktreePath: worktreePath, sessionID: sessionID)
        else { return }

        terminateClaudeSession(for: id)
        await ensureClaudeSession(for: review)
    }
```

- [ ] **Step 6: Seed `terminalIsDark` from settings on load**

This handles an explicit Light/Dark preference at startup (before the view's observer
runs). In `load()`, after `settings` is populated, add a seed. Find the line in `load()`
that assigns `settings` (e.g. `settings = ...`) and, immediately after the settings are
available, add:

```swift
        switch settings.appearance {
        case .light: terminalIsDark = false
        case .dark: terminalIsDark = true
        case .system: break   // resolved by ContentView's colorScheme observer
        }
```

If the exact insertion point in `load()` is unclear, place this seed at the end of
`load()` (after settings are loaded). Report the chosen location.

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd Core && swift test --filter setTerminalAppearanceFlipsOnlyOnChange`
Expected: PASS.

- [ ] **Step 8: Run the full Core suite for regressions**

Run: `cd Core && swift test`
Expected: PASS — all tests green (270+).

- [ ] **Step 9: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(terminal): relaunch selected session on appearance change" --no-verify
```

---

## Task 9: Observe effective color scheme in `ContentView` (App)

**Files:**
- Modify: `App/ContentView.swift` (add `@Environment(\.colorScheme)` to `ContentView`; add observer modifiers after the existing `.onChange(of: model.selection)` at line ~85–91)

- [ ] **Step 1: Add the `colorScheme` environment property**

In `App/ContentView.swift`, the `ContentView` struct declares its stored properties near
the top (`@Bindable var model: AppModel`, `let webViewCache`, `@State private var showingAdd`,
`@State private var showingNewTask`). Add:

```swift
    @Environment(\.colorScheme) private var colorScheme
```

- [ ] **Step 2: Feed the effective scheme to the model**

In `App/ContentView.swift`, the `body` ends with `.onChange(of: model.selection) { ... }`
(around lines 85–91), which closes the `NavigationSplitView` modifier chain. Immediately
after that `.onChange(of: model.selection) { ... }` block, append:

```swift
        .onAppear {
            Task { await model.setTerminalAppearance(isDark: colorScheme == .dark) }
        }
        .onChange(of: colorScheme) { _, newValue in
            Task { await model.setTerminalAppearance(isDark: newValue == .dark) }
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`
(If xcodebuild reports the project is missing, run `xcodegen generate` first.)

- [ ] **Step 4: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(terminal): drive terminal appearance from effective color scheme" --no-verify
```

---

## Task 10: Final verification (build + manual UAT)

**Files:** none (verification only)

- [ ] **Step 1: Full Core test suite**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 2: Clean app build**

Run:
```bash
xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Launch the freshly built binary**

Run: `open -n "DerivedData/Build/Products/Debug/PR Pilot.app"`
(Note: an older copy registered with LaunchServices may exist under
`~/Library/Developer/Xcode/DerivedData/`. Quit other "PR Pilot" instances first so you are
exercising this build.)

- [ ] **Step 4: Manual UAT (requires a live Claude session)**

Select a review with a live Claude session, then in Settings (⌘,) → Appearance toggle
System / Light / Dark. Verify:
- The selected terminal's background flips to light and Claude relaunches (resumes), its
  TUI adopting a light theme; switching back to Dark looks identical to before this work.
- Dark mode terminal is unchanged from today.
- Tune `ClaudeTerminalTheme` light palette values if any ANSI color is hard to read on white.

- [ ] **Step 5: Confirm clean commit history**

Run: `git log --oneline main..HEAD`
Expected: clean conventional-commit subjects, no AI attribution.
