# Issue Status Badge — Design

**Date:** 2026-06-18
**Status:** Approved

## Goal

Show a workflow-status badge on each assigned issue in the PRPilot sidebar
(e.g. "On Hold", "In Review"), conveying where the issue sits in the user's
triage/fix workflow. The status is **derived** from what the app already knows,
with a **manual override** the user can set when the app cannot infer the state
(notably "On Hold").

## Background / why local

The user's assigned issues are not in any GitHub Project and the repo has no
workflow-status labels, so GitHub cannot supply an "On Hold / In Review"
status. The status is therefore a PRPilot-local concept: derived from the
Claude `/start-issue` session lifecycle, with a manually-settable override
persisted in the local store. No GitHub writes.

Scope: issues only (`WorkItem.category(myLogin:) == .issue`). PR and task
sidebar badges are unchanged.

## Status set

A single `IssueWorkStatus` enum with six values:

| Status      | Origin   | Meaning                                                     |
|-------------|----------|------------------------------------------------------------|
| `new`       | derived  | Discovered, not yet evaluated.                             |
| `inReview`  | derived  | The `/start-issue` Claude session is actively working.    |
| `reviewed`  | derived  | That session has completed its evaluation (turn done).    |
| `onHold`    | manual   | The user has parked it.                                    |
| `done`      | manual   | The user considers their work finished.                   |
| `closed`    | derived  | The issue is closed on GitHub (terminal — always wins).   |

The manual override is stored as a *single optional* `IssueWorkStatus?`; the
user may set it to any value (typically `onHold` or `done`, but any of the six),
or clear it to revert to derived. There is no separate "manual-only" subset —
the same enum is used for both derived and manual values.

## Resolution logic (pure, testable)

A free function in `PRPilotModels`:

```swift
public func resolveIssueStatus(
    manual: IssueWorkStatus?,
    prState: PRState?,
    claudeReviewedAt: Date?,
    claudeWorking: Bool
) -> IssueWorkStatus
```

Precedence:

1. `prState == .closed` → `.closed` (always wins, even over a manual value).
2. else if `manual != nil` → `manual!`.
3. else if `claudeWorking` → `.inReview`.
4. else if `claudeReviewedAt != nil` → `.reviewed`.
5. else → `.new`.

Consequences:
- Derivation moves automatically `new → inReview → reviewed` as the Claude
  session runs and finishes.
- A manual value overrides derivation and persists until the user clears it
  ("Clear (Auto)" sets `manualIssueStatus = nil`).
- A GitHub-closed issue always shows `closed`, regardless of any manual value.

## Components

### 1. Model (`PRPilotModels`)

- New `IssueWorkStatus: String, Codable, Sendable, Equatable, CaseIterable`
  with cases `new, inReview, reviewed, onHold, done, closed` and a
  `displayName` (`"New"`, `"In Review"`, `"Reviewed"`, `"On Hold"`, `"Done"`,
  `"Closed"`).
- New stored property `WorkItem.manualIssueStatus: IssueWorkStatus?` —
  `decodeIfPresent`, defaults to `nil`, added to the memberwise init and
  `init(from:)`. Backward-compatible; no schema-version bump.
- The free `resolveIssueStatus(...)` function above.

`manualIssueStatus` is independent of the existing `prState`/`claudeReviewedAt`
fields and does not affect PR or task behavior.

### 2. AppModel (`AppCore`)

- `public func setIssueStatus(_ status: IssueWorkStatus?, for id: String) async`
  — loads the item, sets `manualIssueStatus = status`, upserts, refreshes
  `reviews`. Mirrors the existing `setReviewDisabled(_:for:)`. Passing `nil`
  clears the override.

### 3. UI (`App/ContentView`)

- In `statusBadge(for:)`: when `review.category(myLogin: model.currentLogin)
  == .issue`, render the resolved issue status as a colored badge, computing
  `resolveIssueStatus(manual: review.manualIssueStatus, prState:
  review.prState, claudeReviewedAt: review.claudeReviewedAt, claudeWorking:
  model.claudeStatuses[review.id] == .working)`. PRs and tasks fall through to
  the existing `sidebarStatus` badge.
- Badge colors (reuse the existing `StateBadge` component): New = orange,
  In Review = blue, Reviewed = teal/green, On Hold = gray, Done = purple,
  Closed = red.
- Context menu: for `.issue` items add a "Set Status ▸" submenu with buttons
  `On Hold`, `Done`, `In Review`, `Reviewed`, `New`, a divider, and
  `Clear (Auto)`. Each calls `model.setIssueStatus(...)` (Clear passes `nil`).
  The submenu is shown only for issue items; PR/task context menus are
  unchanged.

### 4. Data flow

```
sidebar render
  → category == .issue?
      → resolveIssueStatus(manualIssueStatus, prState, claudeReviewedAt,
                           claudeStatuses[id] == .working)
      → colored StateBadge
user right-clicks issue → "Set Status ▸ On Hold"
  → model.setIssueStatus(.onHold, for: id)
  → store.upsertItem (manualIssueStatus = .onHold) → reviews reload
  → badge re-renders as "On Hold"
"Set Status ▸ Clear (Auto)"
  → model.setIssueStatus(nil, for: id) → reverts to derived
```

## Error handling

`setIssueStatus` mirrors `setReviewDisabled`: store errors surface via
`errorMessage`. No new failure modes.

## Testing

Unit (existing harness):

- `resolveIssueStatus` truth table:
  - `prState == .closed` → `.closed` even when `manual = .onHold` and
    `claudeWorking = true`.
  - `manual = .onHold`, not closed → `.onHold` (overrides `claudeWorking`).
  - `manual = nil`, `claudeWorking = true` → `.inReview`.
  - `manual = nil`, not working, `claudeReviewedAt != nil` → `.reviewed`.
  - `manual = nil`, not working, `claudeReviewedAt == nil` → `.new`.
- `WorkItem` Codable round-trip carries `manualIssueStatus`; a legacy blob
  without the field decodes to `nil`.
- `AppModel.setIssueStatus` sets and clears `manualIssueStatus` and persists
  (re-read from store reflects the change).

UI (badge rendering, context menu) is verified by a successful
`xcodebuild` build and manual check — consistent with the issue-management
feature's UI tasks.

## Out of scope

- Writing status back to GitHub (labels / Projects v2).
- Status badges for PRs or tasks (unchanged).
- Auto-advancing the manual override (it persists until cleared).
