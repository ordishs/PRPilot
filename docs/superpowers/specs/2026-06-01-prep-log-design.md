# Preparation Log Design

**Date:** 2026-06-01
**Status:** Approved (pending spec review)

## Problem

When a PR pane is selected, PRPilot prepares a git worktree and launches Claude before
the terminal appears. During this window the pane shows a single opaque spinner labelled
"Preparing worktree…". The user has no insight into what is happening, and a slow or stuck
step (e.g. a first-time clone of a large repo, or a hanging git fetch) is indistinguishable
from a fast one — it all looks like the same frozen spinner.

We want live, on-screen feedback of each preparation step ("Locating claude…", "Found
existing clone", "Fetching PR #991…", "Found existing worktree", "Starting fresh /review",
"Session live") rendered as a per-PR log, with the ability to show or hide the detail.

## Goals

- Surface each preparation step as it happens, per PR.
- Show the **current** step inline next to the spinner; offer an expandable, timestamped
  history of all steps.
- Make a slow/stuck step visibly identifiable (it stays on the relevant line).
- Keep the live pane clean once Claude's terminal takes over.

## Non-Goals (YAGNI)

- Persisting the log across app restarts.
- Log levels, filtering, or search.

## Revision (2026-06-01)

The original design discarded the log once the session went live. In practice the prep
window for already-cloned PRs is sub-second (and worktrees are prewarmed at launch), so the
log was effectively never seen. The log is now **retained** after `.sessionLive` and re-opened
on demand from a toggle on the live pane (the persistent-toggle option, originally deferred).
It is still reset at the start of each prep run, so it never shows stale data.

## Architecture

### Data model (AppCore)

```swift
public struct PrepLogEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let message: String
}
```

`AppModel` gains:

```swift
public private(set) var claudePrepLog: [String: [PrepLogEntry]] = [:]   // keyed by review.id
```

and a MainActor-isolated helper:

```swift
private func appendPrepLog(_ message: String, for id: String) {
    claudePrepLog[id, default: []].append(PrepLogEntry(id: UUID(), date: Date(), message: message))
}
```

Because `AppModel` is `@MainActor` and every emit is `await`ed in a single sequential async
chain, entries are appended in step order — no reordering.

### Event plumbing

A progress callback is threaded through the existing worktree seam. Signature:

```swift
typealias PrepProgress = @Sendable (String) async -> Void
```

`WorktreeProviding` gains a progress parameter, with a protocol-extension overload that
preserves the existing 2-argument call sites:

```swift
public protocol WorktreeProviding: Sendable {
    func ensureWorktree(
        for review: Review,
        registeredClonePath: String?,
        progress: @escaping PrepProgress
    ) async throws -> WorktreeReady
}

public extension WorktreeProviding {
    func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> WorktreeReady {
        try await ensureWorktree(for: review, registeredClonePath: registeredClonePath, progress: { _ in })
    }
}
```

Current callers that do not need progress (`WorktreeDiffLoader`, `AppModel.prewarmClaude`'s
non-autoLoad branch) keep using the 2-argument overload unchanged. Only
`AppModel.ensureClaudeSession` passes a real progress closure.

`WorktreeManager.resolveClone` and `WorktreeManager.createWorktree` take the same callback
and emit the fine-grained git steps. `WorktreeProvider.ensureWorktree` emits orchestration
steps and forwards the callback into the manager.

### Step messages by source

| Source | Steps emitted |
|--------|---------------|
| `ensureClaudeSession` | `Locating claude…`, `Reading prior session…`, `Starting fresh /review` / `Resuming session {id}`, `Session live` |
| `WorktreeProvider` | `Detecting remote…`, `Refreshing existing worktree…` (refresh branch) |
| `WorktreeManager.resolveClone` | `Resolving clone…`, `Found existing clone` / `Cloning {owner}/{repo}… (first time, this can take a while)` |
| `WorktreeManager.createWorktree` | `Found existing worktree` / `Pruning stale worktrees…`, `Fetching PR #{n}…`, `Adding worktree…` |

Exact wording may be refined during implementation; the set of steps is what matters.

### Lifecycle

- `ensureClaudeSession` sets `claudePrepLog[id] = []` at the start of a prep run (fresh log
  per attempt, including retries and the clear-session relaunch).
- On `.sessionLive` (success): **retain** `claudePrepLog[id]` so the live pane can re-open it
  via a toggle. (Superseded the original "clear on success" — see Revision above.)
- On `.worktreeFailed`: retain `claudePrepLog[id]` so the failure view can show the steps
  that preceded the error.
- On `.claudeUnavailable`: clear `claudePrepLog[id]` (that view does not surface the log).

### UI (`ClaudePaneView`)

- `.idle` / `.preparingWorktree`:
  - `ProgressView()` plus the **latest** entry's message (fallback "Preparing…" when empty).
  - A `DisclosureGroup("Show details")` containing a scrollable list of all entries rendered
    as `HH:mm:ss  message`, monospaced, selectable.
- `.worktreeFailed(message)`: existing error view, with the same expandable step list shown
  above the error text.
- `.sessionLive`: terminal host with a small "preparation log" button overlaid top-trailing
  (shown only when the log is non-empty); tapping it presents the timestamped history in a
  popover.

A stuck preparation is now diagnosable: the latest line stays on the offending step (e.g.
"Fetching PR #991…") rather than presenting an indistinguishable spinner.

## Error Handling

- Progress emission is best-effort and never throws; a failure to render a line must not
  affect preparation.
- If `ensureWorktree` throws, the partially-accumulated log is preserved (failure branch).
- The progress closure performs no work other than appending to `claudePrepLog`.

## Testing

- `StubWorktreeProvider` implements the 3-argument `ensureWorktree`; it can invoke the
  `progress` closure with scripted lines to simulate steps.
- Model tests:
  - `claudePrepLog[id]` accumulates entries in order during preparation.
  - `claudePrepLog[id]` is cleared once the pane reaches `.sessionLive`.
  - `claudePrepLog[id]` is retained when `ensureWorktree` throws (`.worktreeFailed`).
  - The 2-argument `ensureWorktree` overload still resolves for existing callers.

## Affected Files

- `Core/Sources/AppCore/WorktreeProviding.swift` — protocol param + overload, provider steps.
- `Core/Sources/WorktreeKit/WorktreeManager.swift` — progress params on resolveClone/createWorktree + emits.
- `Core/Sources/AppCore/AppModel.swift` — `PrepLogEntry`, `claudePrepLog`, `appendPrepLog`, emits + lifecycle in `ensureClaudeSession`.
- `App/ClaudePaneView.swift` — latest line + DisclosureGroup history; failure-view step list.
- `Core/Tests/AppCoreTests/AppModelTests.swift` — stub update + new tests.
</content>
</invoke>
