# Triage Trio — Design

**Date:** 2026-06-18
**Status:** Approved

## Goal

Three cohesive sidebar-triage improvements for PRPilot, shipped as one feature:

1. **Awaiting-input status** — distinguish "Claude finished its turn and needs
   you" from generic idle, surfaced as a distinct sidebar dot and used as the
   (sharper) notification trigger.
2. **Sidebar search + filter pills** — a live search field plus All / Active /
   Awaiting pills, so dozens of auto-started items can be cut down to what is
   in flight or needs action.
3. **Ahead/behind chips** — show each editable branch's local ahead/behind
   counts at a glance in the sidebar row.

PR / task / issue behavior is otherwise unchanged. No GitHub writes.

## Part A — "Awaiting input" Claude status

### Status model (`ClaudeSessionKit`)

- Add a case to `ClaudeStatus`:
  `case awaitingInput(since: Date, lastVerdictSnippet: String?)`.
- `ClaudeStatusReader.status(...)` gains one parameter,
  `lastEventWasTurnCompletion: Bool` (default `false` for the existing
  overload/callers). New logic in the `.running` branch:
  1. `guard let lastEventAt else { return .starting }`
  2. if `lastEventWasTurnCompletion` → `.awaitingInput(since: lastEventAt,
     lastVerdictSnippet: lastVerdictSnippet)` — fires immediately, regardless
     of the idle threshold.
  3. else if `now.timeIntervalSince(lastEventAt) < idleThresholdSeconds` →
     `.working`.
  4. else → `.idle(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)`.

`.idle` now means "process running, quiet, and the last event was NOT a clean
turn completion" (interrupted mid-task) — the rare case. `.awaitingInput` is the
common "Claude yielded the turn" case (including `/start-issue` plan-mode stops
via `ExitPlanMode`, which emit `end_turn`).

### AppModel wiring (`AppCore`)

- Track `private var lastEventWasTurnCompletion: [String: Bool] = [:]`.
- In `handleTranscriptEvent(reviewID:at:snippet:turnCompleted:)`, when the event
  is newer (`isNewer`), set `lastEventWasTurnCompletion[reviewID] = turnCompleted`.
- `recomputeStatus(for:now:)` passes
  `lastEventWasTurnCompletion[reviewID] ?? false` into `statusReader.status(...)`.
- Clear `lastEventWasTurnCompletion` for an id in `terminateClaudeSession` and
  the bulk teardown (alongside the other per-session dictionaries).

### Notifications (`AppCore`)

- Rename the intent of the existing gate from idle-based to awaiting-based.
  `shouldFireReviewReady(old:new:reviewID:)` fires when:
  - `new` is `.awaitingInput`, AND
  - the session is not already marked notified (a `notifiedAwaitingForSession`
    set).
- On any transition where `new` is `.working` (Claude resumed / user replied),
  remove the id from `notifiedAwaitingForSession`, re-arming the next
  completion. This yields one notification per completed turn, with at most one
  pending per session.
- `postReviewReadyNotification` reads the snippet from the `.awaitingInput`
  associated value (was `.idle`). Title/body wording is unchanged
  ("Review ready · #N").

### Sidebar dot + tooltip (`App/ContentView`)

- `StatusDot.color`: add `case .awaitingInput: return amber` (a steady amber,
  e.g. `Color.orange` or a custom amber — distinct from working's pulsing blue
  and idle's gray). Awaiting-input does NOT pulse (`isWorking` stays true only
  for `.working`).
- `statusTooltip`: add `case .awaitingInput(let since, let snippet)` →
  "Awaiting input" + elapsed + optional snippet (mirror the `.idle` formatting).

## Part B — Sidebar search + filter pills

### Pure matcher (`PRPilotModels`)

- New `enum SidebarFilter: Sendable, Equatable, CaseIterable { case all, active, awaiting }`.
- New pure function:
  ```swift
  public func sidebarItemMatches(
      _ item: WorkItem,
      query: String,
      filter: SidebarFilter,
      isWorking: Bool,
      isAwaiting: Bool
  ) -> Bool
  ```
  - **Query** (trimmed, case-insensitive): empty → matches; else substring of
    any of: `title`, `"\(owner)/\(repo)"`, `author ?? ""`, `headBranch ?? ""`,
    `"#\(displayNumber.map(String.init) ?? "")"`.
  - **Filter**: `.all` → true; `.active` → `isWorking || isAwaiting`;
    `.awaiting` → `isAwaiting`.
  - Returns query-match AND filter-match.

The status booleans are supplied by the caller, so this function has no
dependency on `ClaudeSessionKit` and is fully unit-testable.

### UI (`App/ContentView`)

- View-local `@State var searchText = ""` and `@State var sidebarFilter: SidebarFilter = .all` (ephemeral; not persisted).
- A header above the `List` (e.g. via `safeAreaInset(edge: .top)` or a wrapping
  `VStack`): a search `TextField` (with a magnifier icon and clear button) and a
  pill row **All / Active / Awaiting**. Active and Awaiting pills show a live
  count of matching items.
- Compute `filtered = model.reviews.filter { sidebarItemMatches($0, query:
  searchText, filter: sidebarFilter, isWorking: isWorking($0), isAwaiting:
  isAwaiting($0)) }`, where `isWorking`/`isAwaiting` derive from
  `model.claudeStatuses[$0.id]` (`== .working`; `if case .awaitingInput`).
- Pass `filtered` to `sidebarSections(items:myLogin:sort:)`. Sections and their
  counts reflect the filtered set; an empty section shows its existing
  "Nothing here yet" placeholder.

## Part C — Ahead/behind chips

### Model (`AppCore`)

- Extend `AppModel.Pushability` with `public var ahead: Int` and
  `public var behind: Int`.
- In `refreshPushability(for:)`, populate them from the `aheadBehind` result:
  - upstream `origin/<branch>` path → `ahead = counts.ahead`,
    `behind = counts.behind`.
  - base fallback path → `ahead = base.ahead`, `behind = 0` (behind-vs-upstream
    unknown).
  - the nil/no-data path → `pushability[id] = nil` (unchanged).
  - `canPush` / `needsForce` keep their current meaning.

### UI (`App/ContentView`)

- In the row's chip area, add chips driven by `model.pushability[review.id]`:
  - `ahead > 0` → `StateBadge(text: "↑\(ahead)", color: .green)` (or neutral).
  - `behind > 0` → `StateBadge(text: "↓\(behind)", color: .orange)`.
  - shown only when `pushability` is present (editable branch worktree on its
    own branch); review-request detached checkouts have no pushability and show
    nothing.
- These coexist with the existing `prStatuses` chips (CI / GitHub-behind /
  changes-requested). The ↑/↓ chips are the local branch-vs-remote counts and
  are visually distinct (arrow glyphs) from the GitHub "behind" badge.

## Error handling

No new failure modes. Status/pushability use existing `try?`/guard paths;
filtering is pure; notification posting is unchanged except for the trigger
state.

## Testing

Unit (`swift test`):

- **`ClaudeStatusReader`**:
  - running + `lastEventWasTurnCompletion = true`, event 0s old → `.awaitingInput`.
  - running + `lastEventWasTurnCompletion = true`, event 10 min old →
    `.awaitingInput` (completion wins over the idle threshold).
  - running + not completed + recent → `.working`.
  - running + not completed + stale → `.idle`.
  - running + no `lastEventAt` → `.starting`.
  - non-running states (`exited`/`failedToLaunch`/`starting`) unchanged.
- **`AppModel`**:
  - a `handleTranscriptEvent(..., turnCompleted: true)` drives the status to
    `.awaitingInput` and fires a notification on `working → awaitingInput`.
  - after a subsequent `.working` event, the gate re-arms and a second
    completion fires again.
  - `refreshPushability` stores `ahead`/`behind` counts (via `StubWorktreeOps`
    `aheadBehind`).
  - existing notification/reviewed-stamp tests updated to the awaiting-input
    trigger (the working→idle notification test becomes working→awaitingInput).
- **`sidebarItemMatches`**: query matches each of title/repo/author/branch/
  number; empty query matches; `.all`/`.active`/`.awaiting` across
  `isWorking`/`isAwaiting` combinations.

UI (search field, pills + counts, dot color, ahead/behind chips) verified by a
successful `xcodebuild` build and a manual check.

## Out of scope

- Persisting the search/filter state across launches (ephemeral by design).
- Live filesystem-watched dirty-tree status (a separate candidate).
- Unread-comment counts (separate candidate).
- Changing the issue workflow-status badge (Part A's dot is the live session
  state, independent of that badge).
