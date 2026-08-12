# Badge Row and Session Queue

Date: 2026-08-12

Two changes that ship together, because the second adds a chip the first must render.

## Part A — One badge line per row

### Problem

Badges live in three places in `App/ContentView.swift:239-282`:

```
Line 1  #1421 · Add retry caps    [New] [Waiting]   ← lifecycle + waiting
Line 2  🔖 label (optional)
Line 3  owner/repo · author
Line 4  [✓ CI] [behind] [changes] [Updated]         ← status chips
Line 5  [↑2] [↓1]                                    ← push chips
Line 6  3 days ago
```

Line 1 is the harmful one. The title carries `.lineLimit(1)` and shares an `HStack` with
the badges, with no `Spacer` between them. Every chip therefore steals width from the
title. Adding the Waiting chip made a long title truncate earlier whenever a PR is waiting.

### Design

All chips move to a single line directly below the title. The title then owns the full
row width. Lines 4 and 5 merge into that same line, so a row with both CI and push chips
loses a line rather than gaining one.

```
#1421 · Add retry caps to the scaling incident path
[New] [Waiting] [✓ CI] [Updated]
🔖 needs perf numbers
bsv-blockchain/teranode · icellan
3 days ago
```

**Order**, fixed, most actionable first:

1. Lifecycle — Merged, Closed, Approved, Reviewed, Draft, New
2. Waiting
3. Queued (Part B)
4. CI — ✓ / ✗ / ◷
5. behind
6. changes
7. Updated
8. push ↑ / ↓

### Overflow

Up to eight chips can appear in a narrow sidebar. They wrap onto another line rather than
clipping: a hidden failing-CI chip is exactly the thing the user most needs to see.

macOS 14 supports the `Layout` protocol, so this is a small custom container.

The line-breaking arithmetic lives apart from SwiftUI, in `AppCore`, so it can be tested:

```swift
public enum FlowRows {
    /// - Returns: subview indices grouped into rows, in order.
    public static func rows(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [[Int]]
}
```

A subview wider than `maxWidth` occupies a row alone rather than being dropped. The
`Layout` conformer, `WrappingHStack` in the `App` target, calls `FlowRows.rows` from both
`sizeThatFits` and `placeSubviews`, so measurement and placement cannot disagree.

## Part B — A real session queue

### Problem

The session cap silently changed what `autoLoad` means.

`prewarmClaude()` runs once, at launch — `App/PRPilotApp.swift:58` is the only caller.
Nothing re-runs it. Inside `prewarmClaudeAndWait`, items past the cap are skipped:

```swift
if claudeSessions.count >= settings.maxLiveClaudeSessions { continue }
```

So they are **skipped, not queued**. On a 36-item store with a cap of 5, the other 31 never
get a session unless the user clicks them. The Settings toggle still reads *"Automatically
start a Claude review for every PR"*, which is no longer true.

A QUEUED chip alone would make this worse. It would label 31 items as waiting for a slot
that never arrives.

### Design

**The queue is derived, not stored.** An item is queued when all hold:

- `settings.autoLoad` is on
- the item is not disabled
- it has no live session
- `claudeReviewedAt == nil` — it has never been reviewed
- its registered clone exists on disk

The last two matter. Keying on `claudeReviewedAt` makes the queue **drain to empty**: each
completed review removes its item permanently. Without it every item would re-queue for
ever and Claude would never stop. Requiring the clone excludes items `prewarmClaudeAndWait`
would skip anyway.

Order is most recently opened first, matching prewarm.

**The drain** runs on the existing five-second tick at `AppModel.swift:140`, which already
walks live sessions. One pure function decides each step:

```swift
public enum SessionQueue {
    public struct Step: Sendable, Equatable {
        public let release: String?   // session to terminate to free a slot
        public let start: String?     // item to start
    }

    public static func nextStep(
        queued: [String],
        live: [SessionBudget.Candidate],
        cap: Int,
        selectedID: String?,
        now: Date
    ) -> Step
}
```

Rules:

- Nothing queued → `Step(release: nil, start: nil)`
- Fewer live sessions than the cap → `Step(release: nil, start: queued.first)`
- At the cap → find the oldest releasable session and return it with the next queued item.
  If none is releasable, do nothing and try again on the next tick.

**Releasable** means not the selected item, and not protected. Protection reuses
`SessionBudget`'s existing rule: `.working` is protected, and `.starting` is protected for
60 seconds. A session in `.ready`, `.idle`, `.awaitingInput` or `.failed` is releasable.

That last point is the slot-release decision. A finished review gives up its process even
though the user has not read it. Nothing is lost: the transcript survives, the Waiting chip
from the badge work says there is something to read, and reopening resumes through
`--resume`, which `ensureClaudeSession` already does at `AppModel.swift:623`.

One step per tick, not a burst. Starting a session does real work, and pacing it keeps the
launch path calm.

### The QUEUED chip

`AppModel` publishes `queuedReviewIDs: [String]`, recomputed whenever the queue inputs
change. The chip renders when the id is in that list. Colour: gray, quieter than Waiting's
yellow, because nothing is required of the user.

### Settings copy

The `autoLoad` toggle description becomes accurate:

> Reviews every PR at least once, `N` at a time. Items above the limit wait their turn and
> show a Queued badge. A finished review releases its slot to the next in line.

### What this costs

The backlog now reviews itself unattended, five at a time, until every item has been
reviewed once. That is real CPU and real token spend — but bounded concurrency was the goal
of the cap, not doing less work overall. Turning `autoLoad` off stops it entirely, and the
queue is empty for anyone who leaves that toggle at its default of false.

## Testing

`FlowRows`:

- One row when everything fits.
- A wrap at the exact boundary, and one item past it.
- An over-wide item occupies its own row and is never dropped.
- Empty input gives no rows.
- Spacing counts between items but not before the first.

`SessionQueue.nextStep`:

- Empty queue does nothing.
- A free slot starts the head of the queue and releases nothing.
- At the cap, the oldest releasable session is released and the head starts.
- A `.working` session is never released.
- A `.starting` session inside its grace is never released.
- The selected item is never released.
- Every session protected means no step at all, and the cap is not exceeded.

Queue derivation:

- `autoLoad` off gives an empty queue.
- A disabled item is excluded.
- An item with a live session is excluded.
- An item with `claudeReviewedAt` set is excluded, which is what makes the queue terminate.
- An item whose clone is missing is excluded.
- Order is most recently opened first.

`AppModel`:

- A tick with a free slot starts a queued session.
- A tick at the cap with one idle session releases it and starts the next.
- The queue empties after every item has been reviewed once, and stays empty.
