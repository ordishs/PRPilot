# Claude Terminal Light Mode — Design

**Date:** 2026-06-03
**Status:** Approved (behavioral decision); spec under review
**Extends:** 2026-06-03-light-mode-design.md

## Problem

The light-mode work makes the whole app follow the appearance setting, but the
Claude review pane hosts a SwiftTerm `LocalProcessTerminalView` whose colors are
never set in our code — it uses SwiftTerm's built-in (dark) defaults. So the
terminal stays dark in light mode. We want it to follow System / Light / Dark.

Complication: Claude Code paints its own truecolor TUI theme and detects the
terminal background **at process launch**. Re-coloring a running terminal changes
the chrome (background, plain text, cursor, scrollback) but not Claude's
already-rendered output. **Decision (approved): on a scheme change, the terminal
chrome follows immediately AND the `claude` process is relaunched (resuming its
session) so Claude re-detects the background and picks its matching light/dark
theme.**

## Key design choice: dark mode is never mutated

Because we relaunch the session on every effective-scheme change, each
`ClaudeSession` is created fresh with a brand-new `LocalProcessTerminalView` that
carries SwiftTerm's pristine defaults. We therefore:

- **Dark target:** do nothing to the terminal — defaults == today's exact look.
  Zero regression risk.
- **Light target:** apply light colors to the freshly-created terminal *before*
  `start()`, so Claude detects a light background on launch.

This sidesteps any need to capture/restore SwiftTerm's default palette.

## Effective scheme, not the raw setting

The trigger is the **effective** `ColorScheme` (`.system` resolves to whatever
macOS is currently showing), so the terminal also tracks OS day/night flips while
the setting is "System". We read it from SwiftUI's `@Environment(\.colorScheme)`
at the app root (which already reflects the `.preferredColorScheme` applied in
Task 2) and push changes into `AppModel`.

## Components

### 1. `ClaudeTerminalTheme` (new, ClaudeSessionKit)

A small type describing the light terminal palette and a function to apply it to a
`LocalProcessTerminalView`. ClaudeSessionKit already imports `SwiftTerm` and
`AppKit`, so `NSColor` and SwiftTerm's `Color` (UInt16 channels, 0–65535) are
available.

- `nativeBackground`, `nativeForeground`, `caret`, `selectionBackground` as
  `NSColor`.
- `ansiPalette: [Color]` — 16 standard ANSI colors tuned for a light background
  (the "bright white"/"white" slots darkened so they remain legible on white).
- `static func applyLight(to view: LocalProcessTerminalView)` which sets
  `view.nativeBackgroundColor`, `view.nativeForegroundColor`, `view.caretColor`,
  `view.selectedTextBackgroundColor`, and calls `view.installColors(ansiPalette)`.

Light values (channels given 0–255; convert to SwiftTerm `Color` via `×257`):
- background `250,250,250`; foreground `30,30,30`; caret `40,40,40`;
  selection `181,213,255`.
- ANSI (normal): black `40,40,40`, red `170,30,30`, green `30,130,40`,
  yellow `150,110,0`, blue `30,80,200`, magenta `150,40,150`, cyan `20,120,140`,
  white `90,90,90`.
- ANSI (bright): black `90,90,90`, red `200,40,40`, green `40,150,50`,
  yellow `170,120,0`, blue `40,90,220`, magenta `170,50,170`, cyan `30,140,160`,
  white `30,30,30`.

(These are starting values; the user will eyeball and we can tune. Dark uses
SwiftTerm defaults — untouched.)

### 2. `ClaudeSession` (ClaudeSessionKit)

Add `func applyLightAppearance()` that calls
`ClaudeTerminalTheme.applyLight(to: terminalView)`. No dark method — dark is the
untouched default. Called by `AppModel` between session creation and `start()`.

### 3. `AppModel` (AppCore)

- New stored property `private(set) var terminalIsDark: Bool = true` (defaults to
  dark = today's behavior until the view reports otherwise).
- In `ensureClaudeSession`, after `let session = ClaudeSession(spec:)` and before
  `session.start()`: `if !terminalIsDark { session.applyLightAppearance() }`.
- New method `func setTerminalAppearance(isDark: Bool)`:
  - If `isDark == terminalIsDark`, return (no-op).
  - Set `terminalIsDark = isDark`.
  - Relaunch **only the currently-selected review's session** (`self.selection`),
    and only if it is live and **safely resumable** (the review has a
    `claudeSessionID` and `ClaudeTranscriptPath.transcriptExists(...)` is true):
    `terminateClaudeSession(for: id)` then `await ensureClaudeSession(for: review)`.
    Re-creation rebuilds the spec with `resume: true` and applies the light theme
    (if light) before launching, so Claude re-detects on the visible pane.
  - **Scope (per decision):** other already-running background sessions are NOT
    relaunched on a toggle. New sessions created after the toggle are themed
    correctly from birth (they read `terminalIsDark` at creation). The only stale
    case is a session created *before* a toggle that is not the selected one — it
    keeps its prior theme until it is independently relaunched/cleared. (Documented
    limitation, accepted to avoid mass `claude` restarts.)
  - The selected session being **not yet resumable** (fresh, no transcript) is also
    left as-is to avoid discarding an in-progress fresh review.

### 4. App layer — scheme observer + wiring

- `ContentView` gains `@Environment(\.colorScheme) private var colorScheme` and a
  modifier that reports the effective scheme to the model:
  `.onAppear { model.setTerminalAppearance(isDark: colorScheme == .dark) }` and
  `.onChange(of: colorScheme) { _, new in Task { await model.setTerminalAppearance(isDark: new == .dark) } }`.
  (`setTerminalAppearance` is async because it awaits `ensureClaudeSession`.)

Because `ContentView` is a descendant of the `.preferredColorScheme(...)` applied
in Task 2, `colorScheme` here is the effective resolved scheme (honors the setting
and OS flips).

## Out of scope

- Theming the GitHub `WebPane` (web content).
- A user-configurable terminal palette / per-theme customization UI.
- Re-detecting theme without a relaunch (not possible with Claude's launch-time
  detection).

## Testing

- **Unit (ClaudeSessionKit):** `ClaudeTerminalTheme.ansiPalette` has exactly 16
  entries; channel conversion (0–255 → 0–65535) is correct for a sampled color.
- **Unit (AppCore):** `setTerminalAppearance(isDark:)` is a no-op when the value is
  unchanged (guard) — verify `terminalIsDark` flips only on change. (Session
  relaunch itself needs a live worktree/claude and is covered by manual UAT.)
- **Manual UAT:** with a live Claude session, toggle System/Light/Dark and confirm
  (a) the terminal background flips, (b) Claude relaunches and resumes, (c) Claude's
  TUI adopts a light theme on white, (d) dark mode looks identical to today.
