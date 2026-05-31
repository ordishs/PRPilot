# PR Pilot

A native macOS app for reviewing GitHub pull requests. One window, a sidebar of
in-progress PRs, and a detail panel that flips between an embedded Claude Code
terminal, a native local diff, and the GitHub PR web view.

Replaces the manual iTerm-plus-browser workflow with a single tool: PRs are
auto-discovered (or added by URL), worktrees are created lazily on first open,
and `claude` runs inside the worktree without leaving the app.

## Status

Phases 1 and 2 are complete. The sidebar auto-populates from `gh search prs`
queries every 120s (configurable), discovered PRs merge with manually-added
ones, status dots reflect live claude session activity (working/idle/ready),
and a "review ready" system notification fires on the first `.working → .idle`
transition per session. The diff pane renders GitHub's "Files changed" layout
natively from local git: file tree on the left, Unified/Split toggle, sticky
file headers with stats, and `@@` hunk header bands.

## The three panes

- **Claude** — `SwiftTerm` `NSView` running the `claude` CLI in a PTY rooted at
  the PR's worktree. One session per review, kept alive across tab/PR switches,
  killed on app quit. First open on a fresh worktree launches with the legacy
  `/review <URL>` slash command + `--name`, `--effort max`,
  `--dangerously-skip-permissions` flags. Subsequent opens (after a prior
  session transcript exists in `~/.claude/projects/<encoded-cwd>/`) launch with
  `--continue` instead, resuming the prior session without re-running the
  review.
- **Diff** — `git diff <merge-base>...<head>` parsed natively and rendered as
  GitHub's "Files changed": file tree on the left, Unified or Split rendering
  on the right, sticky per-file headers, `@@` hunk header bands. Worktrees
  auto-refresh on force-push (fast-forward when clean, warn if dirty). Diff
  state is cached per-review so tab/PR switches are instant.
- **GitHub** — a `WKWebView` on the PR page with a persistent data store so the
  session sticks. Web views are cached per-review for instant tab switches; a
  Refresh button (⌘R) reloads the page.

All three bind to the same selected review; the segmented control swaps which
view is visible. ⌘1 / ⌘2 / ⌘3 jump to Claude / GitHub / Diff respectively.

## Settings

`⌘,` opens the Settings window with three tabs:

- **Discovery** — edit `gh search prs` queries (one per line, include `is:open`
  to filter out closed PRs), poll interval (30-3600 seconds), and sidebar
  grouping (none / by date / by author / by status).
- **Tools** — override paths to `gh`, `git`, and `claude`. Leave blank to
  auto-resolve from `PATH`.
- **Claude** — extra launch arguments (prepended to every `claude`
  invocation) and a notifications-enabled toggle.

Changes save immediately. Changing discovery queries triggers an immediate
poll cycle.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 26 / Swift 6
- [`gh`](https://cli.github.com), `git`, and [`claude`](https://claude.com/claude-code)
  on `PATH`, with `gh auth login` already completed
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
  only needed to regenerate the project file

## Build

```sh
# Generate the Xcode project (gitignored, regenerate any time project.yml changes)
xcodegen generate

# Build and run from Xcode
open PRPilot.xcodeproj

# Or build from the command line
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug \
  -derivedDataPath DerivedData build

# Launch the built app (use -n to force a fresh instance)
open -n "DerivedData/Build/Products/Debug/PR Pilot.app"
```

## Tests

The headless logic lives in the Swift package under `Core/` and carries the
tests:

```sh
cd Core
swift test
```

## Project layout

```
App/                       SwiftUI views and app shell
Core/                      Swift package — headless, unit-testable logic
  Sources/
    PRPilotModels/        Value types shared across modules
    CommandSupport/        Injectable command-runner abstraction
    ReviewStore/           Actor-backed durable state (JSON on disk)
    GitHubKit/             Wraps `gh` (discovery, add-by-URL, metadata)
    WorktreeKit/           Wraps `git` (clone resolution, worktrees)
    DiffKit/               Parses `git diff` into a renderable model
    ClaudeSessionKit/      SwiftTerm-backed PTY session for `claude`
    AppCore/               View-model layer composing the modules
docs/                      Design specs and per-phase implementation plans
project.yml                XcodeGen input that generates PRPilot.xcodeproj
```

## Design

The full design spec, decision log, and per-phase plans live under
`docs/superpowers/`. Start with
`docs/superpowers/specs/2026-05-27-pr-review-app-design.md`.

## Distribution

The Homebrew cask lives in the tap repo `ordishs/homebrew-tap` (`Casks/prpilot.rb`). Cutting a release is one command — `scripts/release.sh` archives, signs, notarises, staples, builds a DMG, and rewrites the cask with the new version + sha256.

One-time setup:

```bash
# DMG builder
brew install create-dmg

# Clone the tap beside this repo (or set TAP_DIR in .env)
git clone git@github.com:ordishs/homebrew-tap.git ../homebrew-tap

# Release config: create a .env in the repo root (gitignored) — the script loads it.
#   DEVELOPMENT_TEAM=ABCDE12345
#   NOTARY_PROFILE=prpilot-notary
# Create the notarytool profile once (see scripts/release.sh header).
```

Cut a release:

```bash
scripts/release.sh 0.1.0
# then follow the printed steps: tag + push the app repo, upload the DMG to
# GitHub Releases, and commit + push the cask in the tap.
```

Users then install via the tap:

```bash
brew install ordishs/tap/prpilot
```

## License

MIT — see [LICENSE](LICENSE).
