# Sidebar Badge Lifecycle

Date: 2026-08-12

## Problem

The sidebar badge for a review request does not track review progress. Clicking a row
changes NEW to REVIEWED, even though the user did nothing but look at it.

Two separate mistakes cause this, both in `Core/Sources/PRPilotModels/SidebarStatus.swift`:

```swift
if approvedByMe { return .approved }
if lastOpenedAt == nil { return .new }
if claudeReviewedAt != nil { return .reviewed }
```

- NEW keys on `lastOpenedAt == nil`. `AppModel.markReviewOpened` stamps `lastOpenedAt`
  when the row is selected, so NEW means "never clicked", not "not yet reviewed".
- REVIEWED keys on `claudeReviewedAt`. That field records Claude completing a turn, not
  the user posting anything. It fires for the state this design calls WAITING.

## Intended behaviour

Two independent signals, not one chain. A row shows at most two chips.

**The lifecycle badge** says how far the user's own review has got. One value, mutually
exclusive:

```
NEW  ──I submit a comment or a change request──▶  REVIEWED  ──I approve──▶  APPROVED
```

- NEW: the user has submitted no review.
- REVIEWED: the user submitted a review of COMMENTED or CHANGES_REQUESTED.
- APPROVED: the user submitted an approval. Sticky — it stays whatever happens next.

**The WAITING chip** says there is Claude output the user has not answered. It appears
and disappears independently of the lifecycle badge.

Together:

```
Never reviewed, Claude not run        #1421  [New]
Claude finished, no response yet      #1421  [New]       [Waiting]
I commented, nothing new since        #1421  [Reviewed]
I approved, nothing new since         #1421  [Approved]
I approved, then Claude re-reviewed   #1421  [Approved]  [Waiting]
```

Separating the two is what lets APPROVED be sticky. The earlier single-chain design had to
choose between "did I approve" and "is there output I have not read". It no longer does.

## Scope

In scope: pull requests whose category is `.reviewRequest`. `WorkItem.category(myLogin:)`
at `WorkItem.swift:143` returns that for any `prRef` whose `authorLogin` is not the
current login.

Out of scope, and deliberately unchanged:

- Issues. They render through `issueStatusBadge` and `resolveIssueStatus`, a separate
  path with its own states.
- The user's own PRs, category `.myPR`. They keep Draft, Open, Merged and Closed.
  Approving or requesting changes on one's own PR is not a real action.
- Tasks, category `.task`.

`lastOpenedAt` stops influencing the badge. It keeps its other jobs: sidebar sort, and
session recency for the Claude session and web view eviction budgets.

## Design

### 1. New data: the user's latest review state

`GitHubClient.fetchPRSnapshot` already builds `myReviews` and then discards everything
except `approvedByMe`:

```swift
let myReviews = pr.reviews.nodes.filter { $0.author?.login == login }
let decisive = myReviews.filter { ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state) }
let approvedByMe = decisive.last?.state == "APPROVED"
```

The GraphQL query at `GitHubClient.swift:221` already returns author, state and
`submittedAt` for every review:

```graphql
reviews(first:100){nodes{author{login} state submittedAt}}
```

So this design needs **no query change and no extra API call**. It reads more from a
response the app already fetches.

A new type in `PRPilotModels`:

```swift
public enum MyReviewState: String, Codable, Sendable, Equatable {
    case none
    case commented
    case changesRequested
    case approved
}
```

Resolution rules, applied to the user's own reviews in submission order. They deliberately
preserve the existing `approvedByMe` result exactly:

- Let the *decisive* review be the newest one whose state is `APPROVED`,
  `CHANGES_REQUESTED` or `DISMISSED`. This is the same set the current code uses.
- Decisive is `APPROVED` → `.approved`
- Decisive is `CHANGES_REQUESTED` → `.changesRequested`
- Decisive is `DISMISSED` → `.commented`. GitHub sets this state on the review itself when
  an approval is dismissed. The user did post a review, so they have engaged, but it is no
  longer an approval or a change request.
- No decisive review, but at least one `COMMENTED` review → `.commented`
- Otherwise → `.none`
- `PENDING` is an unsubmitted draft. It never counts, in any rule above.

Note what the `DISMISSED` rule avoids. Falling back to the review *before* a dismissal
would report `.approved` for a dismissed approval, which would flip `approvedByMe` from
false to true and silently change today's behaviour.

`PRSnapshot` gains two fields:

- `myReviewState: MyReviewState`
- `myLastReviewAt: Date?` — the newest `submittedAt` among the user's reviews in states
  `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED` or `DISMISSED`

`approvedByMe` stays, derived as `myReviewState == .approved`, so existing callers keep
working.

### 2. Persistence

Two new optional fields on `WorkItem`, beside `approvedByMe`. Section 4 adds a third,
`claudeLastCompletedAt`, which follows the same decoding rule:

- `myReviewState: MyReviewState?`
- `myLastReviewAt: Date?`

Both decode through `decodeIfPresent`, matching the file's existing pattern, so an
existing `store.json` stays readable. Persisting them means the badge is correct at
launch, before the first poll, and while offline.

`AppModel.refreshReviewState` writes them through the existing change guard, which only
calls `store.upsertItem` when a value actually differs.

### 3. The lifecycle resolver

`SidebarStatus` keeps its existing cases. WAITING is not one of them, because it is not
part of the chain.

The derivation moves out of the `WorkItem` extension into a free function, matching the
shape of `resolveIssueStatus`:

```swift
public func resolveSidebarStatus(
    category: WorkItemCategory,
    prState: PRState?,
    myReviewState: MyReviewState?
) -> SidebarStatus
```

Precedence:

1. `prState == .merged` → `.merged`
2. `prState == .closed` → `.closed`
3. `category != .reviewRequest` → `.draft` when `prState == .draft`, else `.open`
4. `myReviewState == .approved` → `.approved`
5. `myReviewState` is `.commented` or `.changesRequested` → `.reviewed`
6. `prState == .draft` → `.draft`
7. otherwise → `.new`

Note what leaves and what arrives:

- `lastOpenedAt` and `claudeReviewedAt` are gone from this function. Neither describes
  what the user posted, and both caused the reported bug.
- `.new` moves from near the top of the chain to the fallback. For a review request it now
  means "I have submitted no review", so it persists until the user acts, with no timeout.
  That is the requested behaviour: a PR stuck on NEW truly has had no review.
- `.open` becomes unreachable for `.reviewRequest`, since `.new` is the fallback. It stays
  reachable through step 3 for the user's own PRs and tasks.

**Draft outranks New**, at step 6. An unreviewed draft review-request shows Draft rather
than New, which preserves today's visibility of draft state. Being asked to review a draft
is rare, so the lost NEW signal costs little. Reject this if you would rather see New.

### 4. A timestamp that actually tracks the latest Claude output

`claudeReviewedAt` cannot drive the WAITING chip. It is stamped exactly once. Both call
sites guard on it being nil — `AppModel.swift:716` and `AppModel.swift:995`:

```swift
if turnCompleted, reviews.first(where: { $0.id == reviewID })?.claudeReviewedAt == nil {
```

It therefore means "Claude has reviewed this at least once", and freezes at the first
completion. Driving WAITING from it would show the chip once, hide it when the user
submits a review, and never show it again. The approved-then-re-reviewed case could not
work.

Changing `claudeReviewedAt` to re-stamp is the wrong fix. It also drives
`resolveIssueStatus`, and `clearClaudeSession` at `AppModel.swift:939` clears it to force a
fresh review. Both rely on its one-shot meaning.

So `WorkItem` gains a third field:

- `claudeLastCompletedAt: Date?` — updated on *every* completed turn, with no nil guard

`handleTranscriptEvent` writes it beside the existing one-shot stamp. `clearClaudeSession`
clears it alongside `claudeReviewedAt`, so a cleared session starts clean.

### 5. The WAITING predicate

A separate free function, because it answers a different question:

```swift
public func isAwaitingMyResponse(
    category: WorkItemCategory,
    prState: PRState?,
    claudeLastCompletedAt: Date?,
    myLastReviewAt: Date?
) -> Bool
```

True when all hold:

- `category == .reviewRequest`
- `prState` is neither `.merged` nor `.closed`
- `claudeLastCompletedAt != nil`
- `myLastReviewAt == nil`, or `claudeLastCompletedAt > myLastReviewAt`

Author activity does not feed this predicate. The existing "Updated" chip already reports
that the author moved since the user's last review, and duplicating it here would put two
chips on the same fact.

### 6. Badge rendering

`ContentView.statusBadge` renders the lifecycle badge as it does today, then appends the
WAITING chip when the predicate holds:

```swift
if isAwaitingMyResponse(...) {
    StateBadge(text: "Waiting", color: .yellow)
}
```

Yellow separates it from NEW's orange, REVIEWED's blue and APPROVED's green. A row
therefore shows at most two chips from this design, plus the existing "Updated" chip when
that applies.

## Known limitation

`claudeLastCompletedAt` is stamped on any completed turn. The transcript watcher reports
turn completion, and does not distinguish "the review finished" from "the session answered
a question I asked it". A conversation with the session therefore raises the WAITING chip
without a review having been produced.

This design accepts that. Separating the two means changing what `TranscriptWatcher`
reports, which is a larger piece of work with its own risk. The chip is a better signal
with this limitation than the current badge is without it, and a stale WAITING clears as
soon as the user submits a review.

## Testing

Table-driven tests over `resolveSidebarStatus`, one row per rule:

- Each outcome is reachable.
- A PR with no submitted review gives `.new`, whatever `lastOpenedAt` holds. This is the
  regression test for the reported bug.
- Approval stays `.approved` regardless of `claudeReviewedAt`, pinning the sticky rule.
- A dismissed approval gives `.commented`, and leaves `approvedByMe` false.
- An unreviewed draft review-request gives `.draft`.
- `.myPR`, `.issue` and `.task` categories are unaffected by `myReviewState`.
- Merged and closed win over every other input.

A test that `handleTranscriptEvent` updates `claudeLastCompletedAt` on a *second* completed
turn while leaving `claudeReviewedAt` at its first value. This pins the distinction the
whole WAITING chip depends on, and would have caught the one-shot stamp.

Separate tests over `isAwaitingMyResponse`:

- No completed Claude turn gives false, however long the item has existed.
- A completed turn with no submitted user review gives true.
- A completed turn newer than the user's review gives true; older gives false.
- Equal timestamps give false, so the boundary is pinned.
- True alongside `.approved`, proving the two signals are independent.
- False for `.myPR`, `.issue` and `.task`.
- False once the PR is merged or closed.

A `GitHubClient` test decodes a fixture whose `reviews` array mixes authors and states,
including `PENDING` and `DISMISSED`, and asserts the derived `myReviewState`,
`myLastReviewAt` and `approvedByMe`.

A `WorkItem` decode test proves an existing `store.json` without the two new fields still
loads, with both nil.
