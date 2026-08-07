# "Updated" Badge — Author Responded Since Your Review

**Date:** 2026-08-06
**Status:** Approved

## Problem

When you request changes on a PR (or approve it, or leave comments), nothing in PR Pilot
tells you when the author has moved. The sidebar shows what *you* last did — `Approved`,
`Reviewed` — and that badge never changes when the author replies to your threads, resolves
them, pushes fixes, or asks you to look again. Finding out means opening each PR on GitHub.

We want a sidebar chip, `Updated`, that means: **the author has done something since your
last review**.

## Goals

- Surface author activity that post-dates your most recent review on that PR.
- Fire on any of four signals: a reply in a thread you participated in, a new head commit,
  one of your threads resolved by the author, or a re-request of your review.
- Clear on its own once you review again — no manual grooming, no extra stored state.
- Do it without increasing GitHub API traffic.

## Non-Goals (YAGNI)

- A hover breakdown naming what changed.
- A sidebar filter pill for updated PRs.
- A notification.
- Persisting the flag — it is derived fresh from GitHub each poll cycle.
- Top-level PR comments as a trigger (the four signals above are the agreed set).

## Eligibility and clearing

A PR is eligible only if **you have reviewed it at least once** (any state: approved,
changes requested, or commented). Without one of your reviews there is no anchor to measure
"since" against, so the chip stays off.

The chip shows while the newest author activity is strictly newer than your newest review.
Submitting another review — approval or a further change request — makes your review the
newest word, and the chip clears on the next refresh. Opening the item does not clear it: a
glance is not a re-review.

## Architecture

### 1. `AuthorUpdate` — pure decision function (`PRPilotModels`)

All the logic, no I/O, tested directly:

```swift
public struct ThreadComment: Sendable, Equatable {
    public var authorLogin: String
    public var createdAt: Date
}

public struct ReviewThreadSnapshot: Sendable, Equatable {
    public var isResolved: Bool
    public var resolvedByLogin: String?
    public var comments: [ThreadComment]
}

public enum AuthorUpdate {
    public static func latestUpdate(
        myLogin: String,
        authorLogin: String,
        myReviewDates: [Date],
        threads: [ReviewThreadSnapshot],
        headCommittedAt: Date?,
        reviewRequestedFromMeAt: [Date]
    ) -> Date?
}
```

Returns the newest qualifying author activity, or `nil` when there is none.

1. `guard let myLastReview = myReviewDates.max() else { return nil }` — never reviewed, not
   eligible.
2. Collect candidate timestamps, keeping only those `> myLastReview`:
   - **Replied:** in each thread where you authored a comment, every comment by
     `authorLogin`.
   - **Resolved:** for each thread where you authored a comment and
     `isResolved && resolvedByLogin == authorLogin`, the newest comment timestamp in that
     thread (see approximation below).
   - **Pushed:** `headCommittedAt`.
   - **Re-requested:** each entry of `reviewRequestedFromMeAt`.
3. Return the maximum, or `nil` if no candidate qualifies.

The "thread you participated in" restriction is deliberate. On teranode#1385 the author
replied to Copilot's and github-actions' threads; you were never in those threads, and that
must not badge.

**Approximation — thread resolution has no timestamp.** GitHub's
`PullRequestReviewThread` exposes `isResolved` and `resolvedBy`, but no `resolvedAt`, and
resolve/unresolve does not appear in the PR timeline. The newest comment in the thread is
used as the proxy. Consequence: a thread resolved silently, long after its last comment,
registers as of that last comment and so may not qualify as newer than your review. In
practice the resolve accompanies a reply, which is caught by the "replied" rule anyway.

### 2. `PRStatus` gains one field (`PRPilotModels`)

```swift
public var authorUpdatedAt: Date?   // nil = nothing new since your review
```

`PRStatus` is already the per-item, in-memory carrier for CI, behind, and readiness, and it
already drives the chip row. It is the natural home. Decoding an older persisted payload
defaults the field to `nil`.

### 3. `GitHubClient.fetchPRSnapshot(for:login:)` (`GitHubKit`)

One GraphQL call returning everything the refresh needs:

```swift
public struct PRSnapshot: Sendable, Equatable {
    public let prState: PRState
    public let approvedByMe: Bool
    public let status: PRStatus
}
```

The query fetches `state`, `isDraft`, `reviewDecision`, `mergeStateStatus`, `author`, the
head commit's `committedDate` and `statusCheckRollup`, `reviews`, `reviewThreads`, and
`REVIEW_REQUESTED_EVENT` timeline items. Verified against the live API with no preview
headers required.

This **replaces** `fetchReviewState` and `fetchPRStatus`, which are deleted. Per-PR traffic
per poll cycle drops from two REST calls to one GraphQL call — at 33 tracked items and a
60s interval, from ~66 to ~33 calls/min. That matters: this token hit a GitHub secondary
rate limit during investigation on 2026-08-06.

**CI aggregation.** `statusCheckRollup.contexts` is paginated. The query requests
`first: 100` and feeds the nodes to the existing `PRStatus.aggregateCI`, so behaviour is
unchanged in the normal case (teranode PRs carry ~38 contexts). When `totalCount > 100`,
the unfetched remainder could hide a failure, so the rollup's own `state` field is mapped
instead: `SUCCESS` → passing, `FAILURE`/`ERROR` → failing, `PENDING`/`EXPECTED` → pending.

`reviewThreads` is likewise requested with `first: 100`; beyond that the oldest threads are
not considered, which can only under-report.

**Empty objects from unmatched inline fragments.** A review requested from a *team* returns
`"requestedReviewer": {}` — an empty object, not `null`, because the `... on User` fragment
does not match. Every login-bearing node is therefore decoded with an optional `login`.
This was found by running the client against live PRs, not by fixtures; teranode#1385 and
#1508 both carry team review requests.

### 4. `AppModel.refreshReviewState(for:)` (`AppCore`)

One `fetchPRSnapshot` call in place of the two fetches. It persists `approvedByMe` and
`prState` exactly as before, and assigns `prStatuses[id]`. Failure stays silent and leaves
the previous status in place — a transient error must not blank the chips.

### 5. The chip (`App/ContentView.swift`)

In the existing chip row, after `changes`:

```swift
if status.authorUpdatedAt != nil { StateBadge(text: "Updated", color: .teal) }
```

Teal is unused in the PR chip row (green, red and orange are taken by CI, behind and
changes). The lifecycle badge is untouched, so `Approved` + `Updated` can show together —
that pairing is the point: it says an approval has gone stale.

## Testing

**`AuthorUpdate`** (pure, no network):
- fires on an author reply in a thread you commented in;
- does **not** fire on an author reply in a thread you never touched (the #1385 shape);
- fires on a head commit newer than your review;
- fires when the author resolves a thread you participated in;
- fires on a review re-requested from you;
- returns `nil` when you have never reviewed the PR;
- returns `nil` when your review is newer than every author action (the clearing rule);
- ignores author activity older than your review.

**`GitHubClient.fetchPRSnapshot`**: decoding from a captured GraphQL fixture with mixed
`CheckRun`/`StatusContext` nodes; the `totalCount > 100` fallback to rollup `state`; a
non-zero `gh` exit surfacing as `GitHubError.commandFailed`.

**`AppModel`**: `prStatuses` carries `authorUpdatedAt` after a refresh; the refresh issues
exactly one `gh` invocation.
