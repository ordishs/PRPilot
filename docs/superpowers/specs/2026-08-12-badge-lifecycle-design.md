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

## Intended lifecycle

For a pull request authored by somebody else:

```
NEW  ──Claude review completes──▶  WAITING  ──I submit a review──▶  REVIEWED
                                      │                                │
                                      └──I submit an approval──────────┴──▶  APPROVED
```

- NEW: no Claude review has ever completed.
- WAITING: Claude output exists that the user has not answered.
- REVIEWED: the user submitted a review of COMMENTED or CHANGES_REQUESTED.
- APPROVED: the user submitted an approval.

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

Two new optional fields on `WorkItem`, beside `approvedByMe`:

- `myReviewState: MyReviewState?`
- `myLastReviewAt: Date?`

Both decode through `decodeIfPresent`, matching the file's existing pattern, so an
existing `store.json` stays readable. Persisting them means the badge is correct at
launch, before the first poll, and while offline.

`AppModel.refreshReviewState` writes them through the existing change guard, which only
calls `store.upsertItem` when a value actually differs.

### 3. The status resolver

`SidebarStatus` gains one case, `.waiting`.

The derivation moves out of the `WorkItem` extension into a free function, matching the
shape of `resolveIssueStatus`:

```swift
public func resolveSidebarStatus(
    category: WorkItemCategory,
    prState: PRState?,
    claudeReviewedAt: Date?,
    myReviewState: MyReviewState?,
    myLastReviewAt: Date?
) -> SidebarStatus
```

Precedence:

1. `prState == .merged` → `.merged`
2. `prState == .closed` → `.closed`
3. `category != .reviewRequest` → `.draft` when `prState == .draft`, else `.open`
4. `claudeReviewedAt == nil` and `myReviewState` is nil or `.none` → `.new`
5. Claude output is unanswered → `.waiting`
6. `myReviewState == .approved` → `.approved`
7. `myReviewState` is `.commented` or `.changesRequested` → `.reviewed`
8. `prState == .draft` → `.draft`
9. otherwise → `.open`

"Claude output is unanswered" at step 5 means:

- `claudeReviewedAt != nil`, and
- `myLastReviewAt == nil`, or `claudeReviewedAt > myLastReviewAt`

Step 4 before step 5 gives the requested behaviour for a PR that Claude never ran on: it
shows NEW indefinitely, with no timeout. A PR stuck on NEW is a true signal that nothing
has looked at it.

Step 4 also yields `.new` only when the user has posted nothing. A PR the user reviewed
by hand, without ever running Claude, reaches step 6 or 7 and shows REVIEWED or APPROVED.

**Approval is not sticky.** Step 5 sits above step 6, so a PR the user approved returns to
WAITING when Claude later produces newer output. This is deliberate: the badge answers
"is there Claude output I have not answered", and that question outranks "did I approve".

### 4. Badge rendering

`ContentView.statusBadge` gains one case:

```swift
case .waiting:
    StateBadge(text: "Waiting", color: .yellow)
```

Yellow separates it from NEW's orange and REVIEWED's blue. The existing "Updated" chip,
which flags author activity since the user's last review, is unaffected and complementary.

## Known limitation

`claudeReviewedAt` is stamped by `AppModel.handleTranscriptEvent` whenever Claude
completes a turn:

```swift
if turnCompleted, reviews.first(where: { $0.id == reviewID })?.claudeReviewedAt == nil {
```

It does not distinguish "the review finished" from "any turn finished". A conversation
with the session therefore stamps it, and can push the badge to WAITING without a review
having been produced.

This design accepts that. Separating the two needs a change to what the transcript
watcher reports, which is a larger piece of work with its own risk. The badge is a
better signal with this limitation than the current behaviour is without it.

## Testing

Table-driven tests over `resolveSidebarStatus`, one row per rule:

- Each of the eight outcomes is reachable.
- The timestamp comparison in both directions: Claude newer than the user's review gives
  WAITING; the user's review newer gives REVIEWED or APPROVED.
- Approval followed by newer Claude output gives WAITING, pinning the not-sticky rule.
- A dismissed approval gives `.commented`, and leaves `approvedByMe` false.
- `.myPR` and `.issue` categories are unaffected by the new inputs.
- Merged and closed win over every other input.
- A PR with no Claude review and no user review gives NEW, whatever `lastOpenedAt` holds.

A `GitHubClient` test decodes a fixture whose `reviews` array mixes authors and states,
including `PENDING` and `DISMISSED`, and asserts the derived `myReviewState`,
`myLastReviewAt` and `approvedByMe`.

A `WorkItem` decode test proves an existing `store.json` without the two new fields still
loads, with both nil.
