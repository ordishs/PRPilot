# PR Sidebar Status Indicators + Copy Session ID

**Date:** 2026-05-31
**Status:** Design — approved for planning

## Goal

Make the left-side PR sidebar communicate more at a glance, without clicking into each
PR. Surface where each PR sits in its review lifecycle using a colored status tag, and add
a right-click action to copy a PR's Claude session ID to the clipboard.

## Background

The app is a native macOS SwiftUI app. The sidebar (`App/ContentView.swift`,
`sidebarRow(for:)`) renders each `Review` with its number/title, a small state badge
(currently only Draft/Merged/Closed), owner/repo/author, a relative date, and a live
`StatusDot` reflecting the running Claude session's status.

Relevant existing facts (verified against the codebase):

- `Review` (`Core/Sources/PRReviewModels/Review.swift`) already persists `lastOpenedAt`
  (set by `AppModel.markReviewOpened`) and `prState` (`.open/.draft/.merged/.closed`),
  and `claudeSessionID`.
- `claudeStatuses: [String: ClaudeStatus]` on `AppModel` is **in-memory only**, recomputed
  from process state each ~5s tick and cleared on termination. Claude review completion is
  **not** persisted today.
- The app does **not** know the authenticated GitHub user's login, and does **not** fetch
  PR review data (`gh pr view` requests only
  `number,title,url,state,isDraft,author,headRefName,baseRefName,closingIssuesReferences`).
- A discovery poll runs every `settings.pollIntervalSeconds` (default 120s) via
  `AppModel.startDiscoveryPolling` → `mergeDiscoveryHits`, which refreshes `title`/`prState`
  for PRs returned by the discovery search queries only.
- Clipboard copy already exists: `WebPane.copyURL()` uses `NSPasteboard.general`.
- Review mutation pattern: mutate a `var` copy → `store.upsert(review)` →
  `reviews = await store.allReviews()` (see `markReviewOpened`, `setReviewDisabled`).

## Status lifecycle

A single derived `SidebarStatus` is computed per `Review` and rendered as one colored
capsule per row (reusing the existing `StateBadge` capsule style, with the label text
shown **uppercase** — e.g. `NEW`, `REVIEWED`, `APPROVED`, `MERGED`). Exactly one tag
shows, chosen by precedence (highest wins):

| Priority | Status   | Color  | Condition |
|---------:|----------|--------|-----------|
| 1 | **Merged**   | purple | `prState == .merged` |
| 2 | **Closed**   | red    | `prState == .closed` |
| 3 | **Approved** | green  | `approvedByMe == true` |
| 4 | **New**      | orange | `lastOpenedAt == nil` |
| 5 | **Reviewed** | blue   | `claudeReviewedAt != nil` |
| 6 | **Draft**    | gray   | `prState == .draft` |
| 7 | *(Open)*     | —      | none of the above → no tag |

### Precedence rationale

- **New outranks Reviewed.** The app auto-runs Claude at launch, so a PR can be
  Claude-reviewed before the user has ever opened it. "New" means "you haven't looked,"
  which is precisely the signal that must survive an automated Claude review. Opening the
  PR (`lastOpenedAt` set) drops it to **Reviewed**.
- **Approved / Merged / Closed outrank New** because reaching those states implies the user
  (or the world) has acted; flagging them as "New" would be misleading.
- **Draft** is treated as a low-priority fallback: a draft PR that is also New shows "New."

This replaces the current `stateBadge(for:)` logic, which only rendered Draft/Merged/Closed.

### Dark mode

The app currently runs in dark mode. Tags must use SwiftUI **adaptive system colors**
(`.purple`, `.green`, `.orange`, `.blue`, `.red`, `.gray` / `Color.secondary`) with the
existing tint-background + colored-text pattern, so they recolor correctly for both
appearances. No hard-coded hex values. The tint opacity may be nudged slightly higher
(~0.20–0.24) than the current light-mode `0.18` so the capsule background stays visible
against the dark sidebar; verify contrast in dark mode during implementation.

## Data model changes (`Review.swift`)

Add two persisted fields, both decoded with `decodeIfPresent` + defaults so existing
`store.json` files load without migration:

- `claudeReviewedAt: Date?` — stamped the first time a Claude session for this review
  reaches `.ready`. Makes "Reviewed" durable across app restarts.
- `approvedByMe: Bool` (default `false`) — set from the GitHub review-state poll.

Update the memberwise `init`, the custom `init(from:)`, and `CodingKeys` accordingly.

## "Reviewed" wiring

`AppModel` already posts a notification on the Claude idle→ready transition
(`recomputeStatus`). On that transition, if `claudeReviewedAt` is `nil`, stamp it `Date()`
via the standard mutate→upsert→reload path. The live `StatusDot` remains the real-time
activity indicator (a separate axis from the lifecycle tag), with one enhancement below.

### Live dot — pulse while working

When the Claude status is `.working`, the `StatusDot` **pulses** (a continuous
opacity/scale fade, ~1.1s ease-in-out, auto-reversing) so active work is obvious at a
glance. All other states (`.ready` green, `.idle` gray, `.failed` red, clear) render as a
steady dot. Implemented with a SwiftUI repeating animation gated on
`status == .working`, so the animation starts/stops as the status changes and isn't
running when idle.

## "Approved" wiring (GitHub poll)

### Current user login

Fetch once per launch and cache in-memory on `AppModel` (e.g. `currentLogin: String?`) via
`gh api user --jq .login`. A single cheap call; no persistence required.

### GitHubClient

Extend `GitHubClient` to read review data:

- Add `reviews` (with `author { login }` and `state`) and `reviewDecision` to the
  `gh pr view --json` field list, with the existing older-`gh` fallback preserved.
- Add `fetchReviewState(ref:) -> (approvedByMe: Bool, prState: PRState)`.
  `approvedByMe` is `true` when the **latest** review authored by `currentLogin` has state
  `APPROVED` (ignoring later `DISMISSED`).

### Refresh loop (scope: skip terminal PRs)

Extend the existing poll cycle (and a refresh on PR selection/open) to refresh review state
for all tracked PRs **except** those already `Merged` or `Closed` (terminal states won't
change). For each non-terminal review: call `fetchReviewState`, update `approvedByMe` and
`prState`, then `upsert`. Reuses the established mutation pattern. On `gh` failure for a PR,
leave its existing values unchanged (no error surfaced for background refresh).

## Copy Session ID (context menu)

Add an item to the existing right-click menu in `sidebarRow`, above the Disable/Remove
group:

- **"Copy Session ID"** with `doc.on.clipboard` icon → copies `review.claudeSessionID` via
  `NSPasteboard.general` (mirroring `WebPane.copyURL()`).
- Disabled when `review.claudeSessionID == nil` (no Claude session has started yet).

## Out of scope (YAGNI)

- No new settings or user-configurable toggles; colors and precedence are fixed.
- No second/compound tag — one tag per row by precedence.
- No change to the live `StatusDot` other than the pulse-while-working animation above.
- No store-format migration — new fields default on decode.

## Testing

- `SidebarStatus` derivation: unit-test the precedence function across representative
  field combinations (e.g. merged+approved → Merged; unopened+claudeReviewed → New;
  opened+claudeReviewed → Reviewed; opened+approved → Approved; opened only → no tag;
  draft+unopened → New).
- `Review` Codable round-trip including absence of the new fields (backward compat).
- `GitHubClient.fetchReviewState`: parse a sample `gh pr view` JSON payload and assert
  `approvedByMe` for (a) my latest review APPROVED, (b) my review APPROVED then DISMISSED,
  (c) someone else approved but not me.
- Manual: copy Session ID populates the clipboard; menu item disabled when no session.
