# Badge Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sidebar badge report what the user actually did — NEW until they submit a review, then REVIEWED, then a sticky APPROVED — with an independent WAITING chip for unanswered Claude output.

**Architecture:** Two pure free functions in `PRPilotModels` decide everything: `resolveSidebarStatus` for the lifecycle value, `isAwaitingMyResponse` for the chip. Both take plain values, so they test without a network, a session, or a view. `GitHubClient` derives the user's own review state from reviews the snapshot query already returns, and `AppModel` persists it onto `WorkItem`.

**Tech Stack:** Swift 6, macOS 14, SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Swift Package Manager for `Core/`, XcodeGen for the app target.

**Spec:** `docs/superpowers/specs/2026-08-12-badge-lifecycle-design.md`

## Global Constraints

- Swift tools version 6.0, platform `.macOS(.v14)`. See `Core/Package.swift`.
- Test framework is Swift Testing. Never add XCTest.
- New `WorkItem` fields decode through `decodeIfPresent`, and must be added to the explicit `CodingKeys` enum at `WorkItem.swift:33` — that type does **not** use synthesised keys.
- **No GraphQL query change.** The snapshot query at `GitHubClient.swift:221` already returns every review's author, state and `submittedAt`. Adding a field or a second request is out of scope.
- `approvedByMe` must keep its exact current value in every case. It is derived, not replaced.
- Never write comments unless this plan shows them. The codebase comments the *why*, not the *what*.
- Separate blocks of logic with blank lines.
- Baseline before any change: **429 tests pass, exit code 0**.
- Full test command, run from the repo root: `cd Core && swift test`
- App build: `xcodegen generate` once per fresh checkout, then
  `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`

## Branch Note

This plan is written in the `worktree-resource-limits` worktree, which carries unrelated
resource-limit work. Ask the user whether to branch separately before Task 1. Nothing in
this plan depends on that work.

## Replaced Tests

`Core/Tests/PRPilotModelsTests/SidebarStatusTests.swift` holds nine tests. Four of them
assert the behaviour this plan removes, because they encode the reported bug:

- `unopenedIsNewEvenWhenClaudeReviewed`
- `openedAndClaudeReviewedIsReviewed`
- `unopenedDraftIsNew`
- `openedNothingElseIsOpen`

Task 4 rewrites the file with equivalent-or-greater coverage. These tests are **replaced,
not deleted to reach green** — the requirement changed, and the new file asserts the new
requirement at least as strictly. The remaining five keep their meaning.

## File Structure

**Create:**

- `Core/Sources/PRPilotModels/MyReviewState.swift` — the enum and its resolver
- `Core/Tests/PRPilotModelsTests/MyReviewStateTests.swift`
- `Core/Tests/PRPilotModelsTests/AwaitingResponseTests.swift`

**Modify:**

- `Core/Sources/PRPilotModels/SidebarStatus.swift` — free resolver, new precedence
- `Core/Sources/PRPilotModels/WorkItem.swift` — three new fields
- `Core/Sources/GitHubKit/GitHubClient.swift` — derive and return the new snapshot values
- `Core/Sources/AppCore/AppModel.swift` — persist them; stamp `claudeLastCompletedAt`
- `App/ContentView.swift` — render the WAITING chip
- `Core/Tests/PRPilotModelsTests/SidebarStatusTests.swift` — rewritten
- `Core/Tests/GitHubKitTests/GitHubClientTests.swift`
- `Core/Tests/AppCoreTests/AppModelTests.swift`
- `Core/Tests/PRPilotModelsTests/WorkItemTests.swift`

---

### Task 1: `MyReviewState` and its resolver

**Files:**
- Create: `Core/Sources/PRPilotModels/MyReviewState.swift`
- Test: `Core/Tests/PRPilotModelsTests/MyReviewStateTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `MyReviewState` (`.none`, `.commented`, `.changesRequested`, `.approved`), `MyReviewSubmission(state:submittedAt:)`, and
  `MyReviewState.resolve(from:) -> (state: MyReviewState, lastSubmittedAt: Date?)`

**Why the DISMISSED rule looks odd.** GitHub sets `DISMISSED` on the review itself when an
approval is dismissed. Falling back to the review *before* it would report `.approved` for
a dismissed approval, flipping `approvedByMe` from false to true and silently changing
today's behaviour. `DISMISSED` therefore resolves to `.commented`: the user did post a
review, but it is no longer an approval or a change request.

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/PRPilotModelsTests/MyReviewStateTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

private func submission(_ state: String, _ secondsFromEpoch: TimeInterval?) -> MyReviewSubmission {
    MyReviewSubmission(
        state: state,
        submittedAt: secondsFromEpoch.map { Date(timeIntervalSince1970: $0) }
    )
}

@Test func noReviewsResolvesToNone() {
    let resolved = MyReviewState.resolve(from: [])

    #expect(resolved.state == .none)
    #expect(resolved.lastSubmittedAt == nil)
}

@Test func aCommentedReviewResolvesToCommented() {
    let resolved = MyReviewState.resolve(from: [submission("COMMENTED", 100)])

    #expect(resolved.state == .commented)
    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 100))
}

@Test func anApprovalResolvesToApproved() {
    let resolved = MyReviewState.resolve(from: [
        submission("COMMENTED", 100),
        submission("APPROVED", 200),
    ])

    #expect(resolved.state == .approved)
    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 200))
}

@Test func theNewestDecisiveReviewWinsOverAnOlderOne() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("CHANGES_REQUESTED", 200),
    ])

    #expect(resolved.state == .changesRequested)
}

/// A later COMMENTED review must not override an earlier decisive one, matching the
/// existing `decisive` filter that drives approvedByMe today.
@Test func aLaterCommentDoesNotOverrideAnApproval() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("COMMENTED", 200),
    ])

    #expect(resolved.state == .approved)
    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 200))
}

@Test func aDismissedApprovalResolvesToCommentedNotApproved() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("DISMISSED", 200),
    ])

    #expect(resolved.state == .commented)
}

@Test func aPendingDraftNeverCounts() {
    let resolved = MyReviewState.resolve(from: [submission("PENDING", 100)])

    #expect(resolved.state == .none)
    #expect(resolved.lastSubmittedAt == nil)
}

@Test func lastSubmittedAtIgnoresPendingButCountsComments() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("COMMENTED", 300),
        submission("PENDING", 900),
    ])

    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 300))
}

@Test func aReviewWithNoSubmittedDateStillSetsTheState() {
    let resolved = MyReviewState.resolve(from: [submission("CHANGES_REQUESTED", nil)])

    #expect(resolved.state == .changesRequested)
    #expect(resolved.lastSubmittedAt == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter MyReviewState`
Expected: compile failure — `cannot find 'MyReviewState' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/PRPilotModels/MyReviewState.swift`:

```swift
import Foundation

/// One review the current user submitted, as GitHub reports it.
public struct MyReviewSubmission: Sendable, Equatable {
    public let state: String
    public let submittedAt: Date?

    public init(state: String, submittedAt: Date?) {
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// What the current user has posted on a pull request. Drives the sidebar lifecycle badge.
public enum MyReviewState: String, Codable, Sendable, Equatable {
    case none
    case commented
    case changesRequested
    case approved

    private static let decisiveStates = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
    private static let countedStates = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED", "COMMENTED"]

    /// - Parameter submissions: the user's own reviews, oldest first.
    /// - Returns: the resolved state, and when the user last posted anything.
    public static func resolve(
        from submissions: [MyReviewSubmission]
    ) -> (state: MyReviewState, lastSubmittedAt: Date?) {
        let counted = submissions.filter { countedStates.contains($0.state) }
        let lastSubmittedAt = counted.compactMap(\.submittedAt).max()

        // Mirrors the filter that has always produced approvedByMe, so that value cannot
        // drift. A DISMISSED review is the dismissed review itself, not a separate event,
        // so it must not fall back to whatever it replaced.
        guard let decisive = submissions.last(where: { decisiveStates.contains($0.state) }) else {
            return (counted.isEmpty ? .none : .commented, lastSubmittedAt)
        }

        switch decisive.state {
        case "APPROVED":
            return (.approved, lastSubmittedAt)
        case "CHANGES_REQUESTED":
            return (.changesRequested, lastSubmittedAt)
        default:
            return (.commented, lastSubmittedAt)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter MyReviewState`
Expected: 9 tests pass

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PRPilotModels/MyReviewState.swift Core/Tests/PRPilotModelsTests/MyReviewStateTests.swift
git commit -m "feat(models): resolve the user's own review state from submitted reviews"
```

---

### Task 2: Return the new values from `fetchPRSnapshot`

**Files:**
- Modify: `Core/Sources/GitHubKit/GitHubClient.swift:114-188`
- Test: `Core/Tests/GitHubKitTests/GitHubClientTests.swift`

**Interfaces:**
- Consumes: `MyReviewState.resolve(from:)` and `MyReviewSubmission(state:submittedAt:)` from Task 1
- Produces: `PRSnapshot.myReviewState: MyReviewState` and `PRSnapshot.myLastReviewAt: Date?`

`GitHubKit` already depends on `PRPilotModels`. See `Core/Package.swift`.

- [ ] **Step 1: Write the failing test**

Append to `Core/Tests/GitHubKitTests/GitHubClientTests.swift`:

```swift
private let mixedReviewsSnapshotJSON = """
{"data":{"repository":{"pullRequest":{
  "state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN",
  "author":{"login":"icellan"},
  "commits":{"nodes":[{"commit":{"committedDate":"2026-08-01T10:00:00Z","statusCheckRollup":null}}]},
  "reviews":{"nodes":[
    {"author":{"login":"someone-else"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-02T10:00:00Z"},
    {"author":{"login":"ordishs"},"state":"COMMENTED","submittedAt":"2026-08-03T10:00:00Z"},
    {"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-04T10:00:00Z"},
    {"author":{"login":"ordishs"},"state":"PENDING","submittedAt":null}
  ]},
  "reviewThreads":{"nodes":[]},
  "timelineItems":{"nodes":[]}
}}}}
"""

@Test func snapshotReportsMyLatestReviewStateAndDate() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: mixedReviewsSnapshotJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let snapshot = try await client.fetchPRSnapshot(
        for: PRLocator(owner: "o", repo: "r", number: 1),
        login: "ordishs"
    )

    #expect(snapshot.myReviewState == .approved)
    #expect(snapshot.approvedByMe == true)
    #expect(snapshot.myLastReviewAt == ISO8601DateFormatter().date(from: "2026-08-04T10:00:00Z"))
}

@Test func snapshotIgnoresOtherPeoplesReviews() async throws {
    let json = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[]},
      "reviews":{"nodes":[
        {"author":{"login":"someone-else"},"state":"APPROVED","submittedAt":"2026-08-02T10:00:00Z"}
      ]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let snapshot = try await client.fetchPRSnapshot(
        for: PRLocator(owner: "o", repo: "r", number: 1),
        login: "ordishs"
    )

    #expect(snapshot.myReviewState == .none)
    #expect(snapshot.approvedByMe == false)
    #expect(snapshot.myLastReviewAt == nil)
}

@Test func snapshotTreatsADismissedApprovalAsCommented() async throws {
    let json = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[]},
      "reviews":{"nodes":[
        {"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-02T10:00:00Z"},
        {"author":{"login":"ordishs"},"state":"DISMISSED","submittedAt":"2026-08-03T10:00:00Z"}
      ]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let snapshot = try await client.fetchPRSnapshot(
        for: PRLocator(owner: "o", repo: "r", number: 1),
        login: "ordishs"
    )

    #expect(snapshot.myReviewState == .commented)
    #expect(snapshot.approvedByMe == false)
}
```

`RecordingRunner` is the stub already defined at the top of that file, and it has an
`init(result:)` that returns the same `CommandResult` for every call. Note that
`AppCoreTests` names its equivalent stub `StubRunner` — do not mix them up.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter snapshotReportsMyLatest`
Expected: compile failure — `value of type 'PRSnapshot' has no member 'myReviewState'`

- [ ] **Step 3: Extend `PRSnapshot`**

In `Core/Sources/GitHubKit/GitHubClient.swift`, replace the `PRSnapshot` struct at line 114:

```swift
    public struct PRSnapshot: Sendable, Equatable {
        public let prState: PRState
        public let approvedByMe: Bool
        public let myReviewState: MyReviewState
        public let myLastReviewAt: Date?
        public let status: PRStatus

        public init(
            prState: PRState,
            approvedByMe: Bool,
            myReviewState: MyReviewState = .none,
            myLastReviewAt: Date? = nil,
            status: PRStatus
        ) {
            self.prState = prState
            self.approvedByMe = approvedByMe
            self.myReviewState = myReviewState
            self.myLastReviewAt = myLastReviewAt
            self.status = status
        }
    }
```

The defaults keep any existing construction site compiling.

- [ ] **Step 4: Derive the values**

Replace these three lines in `fetchPRSnapshot`:

```swift
        let myReviews = pr.reviews.nodes.filter { $0.author?.login == login }
        let decisive = myReviews.filter { ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state) }
        let approvedByMe = decisive.last?.state == "APPROVED"
```

with:

```swift
        let myReviews = pr.reviews.nodes.filter { $0.author?.login == login }
        let resolved = MyReviewState.resolve(
            from: myReviews.map { MyReviewSubmission(state: $0.state, submittedAt: $0.submittedAt) }
        )
        let approvedByMe = resolved.state == .approved
```

Add `import PRPilotModels` to the file if it is absent.

Then extend the returned value:

```swift
        return PRSnapshot(
            prState: GitHubClient.mapState(state: pr.state, isDraft: pr.isDraft),
            approvedByMe: approvedByMe,
            myReviewState: resolved.state,
            myLastReviewAt: resolved.lastSubmittedAt,
            status: PRStatus(
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter snapshot`
Expected: the three new tests pass, and every pre-existing `snapshot` test still passes.
The `approvedByMe` assertions in those older tests are the guard that this refactor did not
change its value.

- [ ] **Step 6: Run the full suite**

Run: `cd Core && swift test`
Expected: 441 tests pass, exit code 0

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/GitHubKit/GitHubClient.swift Core/Tests/GitHubKitTests/GitHubClientTests.swift
git commit -m "feat(github): report the user's own review state in the PR snapshot"
```

---

### Task 3: Persist the three new `WorkItem` fields

**Files:**
- Modify: `Core/Sources/PRPilotModels/WorkItem.swift`
- Test: `Core/Tests/PRPilotModelsTests/WorkItemTests.swift`

**Interfaces:**
- Consumes: `MyReviewState` from Task 1
- Produces: `WorkItem.myReviewState: MyReviewState?`, `WorkItem.myLastReviewAt: Date?`, `WorkItem.claudeLastCompletedAt: Date?`

`WorkItem` declares `CodingKeys` explicitly at line 33. A new property that is not added
there will silently never encode or decode.

- [ ] **Step 1: Write the failing tests**

Append to `Core/Tests/PRPilotModelsTests/WorkItemTests.swift`:

```swift
@Test func workItemWithoutTheNewReviewFieldsDecodesWithNils() throws {
    let json = """
    {
      "id": "abc",
      "title": "t",
      "repoKey": "github.com/o/r",
      "baseBranch": "main",
      "origin": "added",
      "addedAt": "2026-08-01T10:00:00Z",
      "disabled": false,
      "viewedFiles": [],
      "approvedByMe": false,
      "autoReview": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))

    #expect(item.myReviewState == nil)
    #expect(item.myLastReviewAt == nil)
    #expect(item.claudeLastCompletedAt == nil)
}

@Test func workItemRoundTripsTheNewReviewFields() throws {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0)
    )
    item.myReviewState = .changesRequested
    item.myLastReviewAt = Date(timeIntervalSince1970: 500)
    item.claudeLastCompletedAt = Date(timeIntervalSince1970: 900)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: encoder.encode(item))

    #expect(decoded.myReviewState == .changesRequested)
    #expect(decoded.myLastReviewAt == Date(timeIntervalSince1970: 500))
    #expect(decoded.claudeLastCompletedAt == Date(timeIntervalSince1970: 900))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter workItem`
Expected: compile failure — `value of type 'WorkItem' has no member 'myReviewState'`

- [ ] **Step 3: Add the properties**

In `Core/Sources/PRPilotModels/WorkItem.swift`, after the `authorUpdateSeenAt` property:

```swift
    /// What the user has posted on this PR, from the last poll. Persisted so the sidebar
    /// badge is right at launch, before the first refresh, and while offline.
    public var myReviewState: MyReviewState?
    /// When the user last submitted a review of any kind.
    public var myLastReviewAt: Date?
    /// When Claude last completed a turn. Unlike `claudeReviewedAt`, which is stamped once
    /// and then frozen, this updates every time, so the Waiting chip can return after the
    /// user responds and Claude runs again.
    public var claudeLastCompletedAt: Date?
```

- [ ] **Step 4: Add the coding keys**

Extend the `CodingKeys` enum:

```swift
        case label, lastPane, authorUpdateSeenAt
        case myReviewState, myLastReviewAt, claudeLastCompletedAt
```

- [ ] **Step 5: Decode them**

Find the `init(from:)` line that decodes `authorUpdateSeenAt` and add beneath it:

```swift
        myReviewState = try c.decodeIfPresent(MyReviewState.self, forKey: .myReviewState)
        myLastReviewAt = try c.decodeIfPresent(Date.self, forKey: .myLastReviewAt)
        claudeLastCompletedAt = try c.decodeIfPresent(Date.self, forKey: .claudeLastCompletedAt)
```

If `WorkItem` relies on a synthesised `init(from:)`, skip this step — `decodeIfPresent`
semantics come free for optional properties. Check the file before editing.

Do **not** add these to the memberwise `init`. Every construction site sets them by
assignment, and adding three more defaulted parameters to an initialiser that already takes
twenty is not worth it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Core && swift test --filter workItem`
Expected: the two new tests pass, plus the existing `WorkItem` tests

- [ ] **Step 7: Run the full suite**

Run: `cd Core && swift test`
Expected: 443 tests pass, exit code 0

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/PRPilotModels/WorkItem.swift Core/Tests/PRPilotModelsTests/WorkItemTests.swift
git commit -m "feat(models): persist the user's review state and Claude's last completion"
```

---

### Task 4: The lifecycle resolver

**Files:**
- Modify: `Core/Sources/PRPilotModels/SidebarStatus.swift`
- Modify: `App/ContentView.swift:381`
- Test: `Core/Tests/PRPilotModelsTests/SidebarStatusTests.swift` (rewritten — see "Replaced Tests")

**Interfaces:**
- Consumes: `MyReviewState` from Task 1, `WorkItem.myReviewState` from Task 3
- Produces: `resolveSidebarStatus(category:prState:myReviewState:) -> SidebarStatus` and `WorkItem.sidebarStatus(myLogin:) -> SidebarStatus`

`sidebarStatus` changes from a computed property to a method taking `myLogin`, because the
new precedence depends on category. `App/ContentView.swift:381` is the only production call
site, and it already has `model.currentLogin` in hand.

- [ ] **Step 1: Rewrite the test file**

Replace the whole of `Core/Tests/PRPilotModelsTests/SidebarStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

private func review(
    prState: PRState = .open,
    authorLogin: String = "someone-else",
    lastOpenedAt: Date? = nil,
    claudeReviewedAt: Date? = nil,
    myReviewState: MyReviewState? = nil
) -> WorkItem {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "h",
        prRef: PRRef(
            owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: authorLogin
        ),
        prState: prState,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0),
        lastOpenedAt: lastOpenedAt,
        claudeReviewedAt: claudeReviewedAt
    )
    item.myReviewState = myReviewState
    return item
}

private let me = "ordishs"

@Test func mergedBeatsEverything() {
    let item = review(prState: .merged, myReviewState: .approved)

    #expect(item.sidebarStatus(myLogin: me) == .merged)
}

@Test func closedBeatsApproved() {
    let item = review(prState: .closed, myReviewState: .approved)

    #expect(item.sidebarStatus(myLogin: me) == .closed)
}

@Test func approvedBeatsReviewed() {
    #expect(review(myReviewState: .approved).sidebarStatus(myLogin: me) == .approved)
}

@Test func aCommentedReviewIsReviewed() {
    #expect(review(myReviewState: .commented).sidebarStatus(myLogin: me) == .reviewed)
}

@Test func aChangeRequestIsReviewed() {
    #expect(review(myReviewState: .changesRequested).sidebarStatus(myLogin: me) == .reviewed)
}

/// The reported bug: clicking a row stamps lastOpenedAt, which used to clear NEW.
@Test func openingTheRowDoesNotClearNew() {
    let item = review(lastOpenedAt: Date(timeIntervalSince1970: 500))

    #expect(item.sidebarStatus(myLogin: me) == .new)
}

/// The other half of the bug: a completed Claude turn used to read as REVIEWED.
@Test func aCompletedClaudeReviewDoesNotMakeItReviewed() {
    let item = review(
        lastOpenedAt: Date(timeIntervalSince1970: 500),
        claudeReviewedAt: Date(timeIntervalSince1970: 600)
    )

    #expect(item.sidebarStatus(myLogin: me) == .new)
}

@Test func approvalStaysApprovedAfterANewerClaudeReview() {
    let item = review(
        claudeReviewedAt: Date(timeIntervalSince1970: 9_000),
        myReviewState: .approved
    )

    #expect(item.sidebarStatus(myLogin: me) == .approved)
}

@Test func anUnreviewedDraftIsDraft() {
    #expect(review(prState: .draft).sidebarStatus(myLogin: me) == .draft)
}

@Test func approvedDraftIsApproved() {
    #expect(review(prState: .draft, myReviewState: .approved).sidebarStatus(myLogin: me) == .approved)
}

@Test func aNeverReviewedRequestIsNewIndefinitely() {
    #expect(review().sidebarStatus(myLogin: me) == .new)
}

@Test func myOwnOpenPRIsOpenNotNew() {
    let item = review(authorLogin: me)

    #expect(item.sidebarStatus(myLogin: me) == .open)
}

@Test func myOwnDraftPRIsDraft() {
    let item = review(prState: .draft, authorLogin: me)

    #expect(item.sidebarStatus(myLogin: me) == .draft)
}

@Test func myOwnPRIgnoresMyReviewState() {
    let item = review(authorLogin: me, myReviewState: .approved)

    #expect(item.sidebarStatus(myLogin: me) == .open)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter sidebarStatus`
Expected: compile failure — `cannot call value of non-function type 'SidebarStatus'`, because `sidebarStatus` is still a property

- [ ] **Step 3: Write the implementation**

Replace the extension in `Core/Sources/PRPilotModels/SidebarStatus.swift`:

```swift
/// Resolves the single lifecycle badge. It answers one question: how far has the user's
/// own review got? Whether Claude has produced unread output is a separate signal —
/// see `isAwaitingMyResponse`.
///
/// `lastOpenedAt` and `claudeReviewedAt` are deliberately absent. Neither describes what
/// the user posted, and keying NEW and REVIEWED on them made the badge report progress
/// the user had not made.
public func resolveSidebarStatus(
    category: WorkItemCategory,
    prState: PRState?,
    myReviewState: MyReviewState?
) -> SidebarStatus {
    switch prState {
    case .merged: return .merged
    case .closed: return .closed
    case .open, .draft, .none: break
    }

    guard category == .reviewRequest else {
        return prState == .draft ? .draft : .open
    }

    switch myReviewState {
    case .approved: return .approved
    case .commented, .changesRequested: return .reviewed
    case .none, .some(.none): break
    }

    if prState == .draft { return .draft }
    return .new
}

extension WorkItem {
    public func sidebarStatus(myLogin: String?) -> SidebarStatus {
        resolveSidebarStatus(
            category: category(myLogin: myLogin),
            prState: prState,
            myReviewState: myReviewState
        )
    }
}
```

`case .none, .some(.none)` covers both an absent value and an explicit `MyReviewState.none`.
Swift needs both spellings for an optional enum whose payload has a `none` case.

- [ ] **Step 4: Update the only production call site**

In `App/ContentView.swift:381`, change:

```swift
            switch review.sidebarStatus {
```

to:

```swift
            switch review.sidebarStatus(myLogin: model.currentLogin) {
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter sidebarStatus`
Expected: 14 tests pass

- [ ] **Step 6: Run the full suite**

Run: `cd Core && swift test`
Expected: 448 tests pass, exit code 0

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PRPilotModels/SidebarStatus.swift Core/Tests/PRPilotModelsTests/SidebarStatusTests.swift App/ContentView.swift
git commit -m "fix(sidebar): base the lifecycle badge on reviews the user submitted"
```

---

### Task 5: The WAITING predicate

**Files:**
- Modify: `Core/Sources/PRPilotModels/SidebarStatus.swift`
- Test: `Core/Tests/PRPilotModelsTests/AwaitingResponseTests.swift`

**Interfaces:**
- Consumes: `WorkItemCategory`, `PRState`, `WorkItem.claudeLastCompletedAt` and `WorkItem.myLastReviewAt` from Task 3
- Produces: `isAwaitingMyResponse(category:prState:claudeLastCompletedAt:myLastReviewAt:) -> Bool` and `WorkItem.awaitsMyResponse(myLogin:) -> Bool`. The two names differ on purpose — see Step 3.

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/PRPilotModelsTests/AwaitingResponseTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

@Test func noCompletedClaudeTurnIsNotWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: nil,
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func aCompletedTurnWithNoReviewFromMeIsWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(100),
        myLastReviewAt: nil
    )

    #expect(waiting == true)
}

@Test func claudeNewerThanMyReviewIsWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: at(100)
    )

    #expect(waiting == true)
}

@Test func myReviewNewerThanClaudeIsNotWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(100),
        myLastReviewAt: at(200)
    )

    #expect(waiting == false)
}

@Test func equalTimestampsAreNotWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(100),
        myLastReviewAt: at(100)
    )

    #expect(waiting == false)
}

@Test func aMergedPRIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .merged,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func aClosedPRIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .closed,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func myOwnPRIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .myPR,
        prState: .open,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func anIssueIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .issue,
        prState: .open,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func aTaskIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .task,
        prState: nil,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

/// The two signals are independent: an approved PR still shows Waiting when Claude has
/// produced newer output. This is the case the single-chain design could not express.
@Test func anApprovedPRCanStillBeWaiting() {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        prRef: PRRef(
            owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: "someone-else"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0)
    )
    item.myReviewState = .approved
    item.myLastReviewAt = at(100)
    item.claudeLastCompletedAt = at(200)

    #expect(item.sidebarStatus(myLogin: "ordishs") == .approved)
    #expect(item.awaitsMyResponse(myLogin: "ordishs") == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter Waiting`
Expected: compile failure — `cannot find 'isAwaitingMyResponse' in scope`

- [ ] **Step 3: Write the implementation**

Append to `Core/Sources/PRPilotModels/SidebarStatus.swift`:

```swift
/// Whether Claude has produced output on a review request that the user has not answered.
///
/// Independent of `resolveSidebarStatus` on purpose: "did I approve this" and "is there
/// output I have not read" are different questions, and a PR can be both approved and
/// waiting. Author activity is not considered here — the "Updated" chip already reports it.
public func isAwaitingMyResponse(
    category: WorkItemCategory,
    prState: PRState?,
    claudeLastCompletedAt: Date?,
    myLastReviewAt: Date?
) -> Bool {
    guard category == .reviewRequest else { return false }
    guard prState != .merged, prState != .closed else { return false }
    guard let claudeLastCompletedAt else { return false }
    guard let myLastReviewAt else { return true }
    return claudeLastCompletedAt > myLastReviewAt
}

extension WorkItem {
    public func awaitsMyResponse(myLogin: String?) -> Bool {
        isAwaitingMyResponse(
            category: category(myLogin: myLogin),
            prState: prState,
            claudeLastCompletedAt: claudeLastCompletedAt,
            myLastReviewAt: myLastReviewAt
        )
    }
}
```

The method is deliberately named `awaitsMyResponse`, not `isAwaitingMyResponse`. Qualifying
the free function as `PRPilotModels.isAwaitingMyResponse` does not work here: `Schema.swift:1`
declares `public enum PRPilotModels`, so that prefix resolves to the enum rather than the
module, and the call fails to compile. Distinct names avoid the problem entirely.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter Waiting`
Expected: 11 tests pass

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 459 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PRPilotModels/SidebarStatus.swift Core/Tests/PRPilotModelsTests/AwaitingResponseTests.swift
git commit -m "feat(sidebar): add the awaiting-my-response predicate"
```

---

### Task 6: Persist the review state on refresh

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift:1005-1029`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `PRSnapshot.myReviewState` and `PRSnapshot.myLastReviewAt` from Task 2, the `WorkItem` fields from Task 3
- Produces: no new API — `refreshReviewState(for:)` keeps its signature

- [ ] **Step 1: Write the failing test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`. Reuse the existing helpers
`tempStoreURL()`, `cappedReview(_:number:openedMinutesAgo:)` and `cappedModel(store:)`:

```swift
@Test @MainActor func refreshPersistsMyReviewStateAndDate() async throws {
    let snapshotJSON = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[]},
      "reviews":{"nodes":[
        {"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-04T10:00:00Z"}
      ]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("rev", number: 1, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let client = GitHubClient(
        runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")),
        ghPath: "gh"
    )
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    model.setCurrentLoginForTesting("ordishs")

    await model.refreshReviewState(for: item.id)

    let stored = await store.item(id: item.id)

    #expect(model.reviews.first { $0.id == item.id }?.myReviewState == .changesRequested)
    #expect(stored?.myReviewState == .changesRequested)
    #expect(stored?.myLastReviewAt == ISO8601DateFormatter().date(from: "2026-08-04T10:00:00Z"))
}
```

`currentLogin` is `private(set)`, and `load()` sets it from a stub that returns an empty
login. Step 3 adds a test seam beside the existing `setPRStatusForTesting`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Core && swift test --filter refreshPersistsMyReview`
Expected: compile failure — `value of type 'AppModel' has no member 'setCurrentLoginForTesting'`

- [ ] **Step 3: Add the seam and persist the fields**

In `Core/Sources/AppCore/AppModel.swift`, beside `setPRStatusForTesting`:

```swift
    func setCurrentLoginForTesting(_ login: String) {
        currentLogin = login
    }
```

Then replace the change guard inside `refreshReviewState(for:)`:

```swift
        if var current = reviews.first(where: { $0.id == id }),
           current.approvedByMe != snapshot.approvedByMe
            || current.prState != snapshot.prState
            || current.myReviewState != snapshot.myReviewState
            || current.myLastReviewAt != snapshot.myLastReviewAt {
            current.approvedByMe = snapshot.approvedByMe
            current.prState = snapshot.prState
            current.myReviewState = snapshot.myReviewState
            current.myLastReviewAt = snapshot.myLastReviewAt
            do {
                try await store.upsertItem(current)
                reviews = await store.allItems()
            } catch {
                errorMessage = String(describing: error)
            }
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Core && swift test --filter refreshPersistsMyReview`
Expected: 1 test passes

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 460 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): persist the user's review state from each refresh"
```

---

### Task 7: Stamp `claudeLastCompletedAt` on every completed turn

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift:716`, `:939`, `:995`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `WorkItem.claudeLastCompletedAt` from Task 3
- Produces: no new API

**The bug this exists to avoid.** `claudeReviewedAt` is stamped once. Both `AppModel.swift:716`
and `markClaudeReviewed` at `:995` guard on it being nil, and only `clearClaudeSession` at
`:939` resets it. Driving the WAITING chip from it would show the chip once, hide it when
the user submits a review, and never show it again.

- [ ] **Step 1: Write the failing test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
/// The distinction the Waiting chip depends on: the one-shot stamp must stay put while the
/// latest-completion stamp moves.
@Test @MainActor func aSecondCompletedTurnMovesOnlyTheLatestStamp() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("turns", number: 1, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()
    await model.ensureClaudeSession(for: item)

    let first = Date(timeIntervalSince1970: 1_000)
    model.handleTranscriptEvent(reviewID: item.id, at: first, snippet: "done", turnCompleted: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    let afterFirst = model.reviews.first { $0.id == item.id }

    let second = Date(timeIntervalSince1970: 2_000)
    model.handleTranscriptEvent(reviewID: item.id, at: second, snippet: "done again", turnCompleted: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    let afterSecond = model.reviews.first { $0.id == item.id }

    #expect(afterFirst?.claudeReviewedAt != nil)
    #expect(afterFirst?.claudeLastCompletedAt != nil)
    #expect(afterSecond?.claudeReviewedAt == afterFirst?.claudeReviewedAt)
    #expect(afterSecond?.claudeLastCompletedAt != afterFirst?.claudeLastCompletedAt)
}

@Test @MainActor func clearingASessionClearsBothClaudeStamps() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("clear", number: 1, openedMinutesAgo: 1)
    item.claudeReviewedAt = Date(timeIntervalSince1970: 1_000)
    item.claudeLastCompletedAt = Date(timeIntervalSince1970: 2_000)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()

    await model.clearClaudeSession(for: item.id)

    let stored = await store.item(id: item.id)

    #expect(stored?.claudeReviewedAt == nil)
    #expect(stored?.claudeLastCompletedAt == nil)
}
```

Both stamps are written from a detached `Task`, so each assertion follows a short sleep.
This matches the existing `awaitingInputFiresNotificationOnceAndRearms` test in the file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ClaudeStamp`
Expected: `aSecondCompletedTurnMovesOnlyTheLatestStamp` fails on `afterFirst?.claudeLastCompletedAt != nil`, because nothing writes the field yet

- [ ] **Step 3: Stamp on every completed turn**

In `Core/Sources/AppCore/AppModel.swift`, replace the block at line 716:

```swift
        // "Reviewed" means Claude actually completed a turn (stop_reason end_turn) — not
        // merely that the session went idle, which also happens when a review is
        // interrupted mid-task and later resumed.
        if turnCompleted, reviews.first(where: { $0.id == reviewID })?.claudeReviewedAt == nil {
            Task { await self.markClaudeReviewed(reviewID) }
        }
```

with:

```swift
        // "Reviewed" means Claude actually completed a turn (stop_reason end_turn) — not
        // merely that the session went idle, which also happens when a review is
        // interrupted mid-task and later resumed.
        if turnCompleted {
            Task { await self.markClaudeTurnCompleted(reviewID) }
        }
```

- [ ] **Step 4: Rewrite `markClaudeReviewed`**

Replace `markClaudeReviewed(_:)` at line 995:

```swift
    /// `claudeReviewedAt` records the *first* completion and then stays put; other code
    /// treats it as "Claude has looked at this at least once". `claudeLastCompletedAt`
    /// moves every time, which is what lets the Waiting chip come back after the user
    /// responds and Claude runs again.
    func markClaudeTurnCompleted(_ id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        let now = Date()
        if review.claudeReviewedAt == nil {
            review.claudeReviewedAt = now
        }
        review.claudeLastCompletedAt = now
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }
```

Keep whatever error handling the original had. If any other code calls
`markClaudeReviewed`, update those call sites to the new name — check with
`grep -rn markClaudeReviewed Core App`.

- [ ] **Step 5: Clear the new stamp too**

In `clearClaudeSession(for:)` at line 939, after `review.claudeReviewedAt = nil`:

```swift
        review.claudeLastCompletedAt = nil
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Core && swift test --filter "aSecondCompletedTurn|clearingASession"`
Expected: 2 tests pass

- [ ] **Step 7: Run the full suite**

Run: `cd Core && swift test`
Expected: 462 tests pass, exit code 0

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): track Claude's latest turn completion separately"
```

---

### Task 8: Render the WAITING chip

**Files:**
- Modify: `App/ContentView.swift:376-397`

**Interfaces:**
- Consumes: `WorkItem.awaitsMyResponse(myLogin:)` from Task 5
- Produces: nothing

No automated test. The `App` target has no test target; Tasks 4 and 5 cover the decisions.

- [ ] **Step 1: Render both chips**

In `App/ContentView.swift`, replace `statusBadge(for:)`:

```swift
    @ViewBuilder
    private func statusBadge(for review: WorkItem) -> some View {
        if review.category(myLogin: model.currentLogin) == .issue {
            issueStatusBadge(for: review)
        } else {
            switch review.sidebarStatus(myLogin: model.currentLogin) {
            case .merged:
                StateBadge(text: "Merged", color: .purple)
            case .closed:
                StateBadge(text: "Closed", color: .red)
            case .approved:
                StateBadge(text: "Approved", color: .green)
            case .new:
                StateBadge(text: "New", color: .orange)
            case .reviewed:
                StateBadge(text: "Reviewed", color: .blue)
            case .draft:
                StateBadge(text: "Draft", color: .gray)
            case .open:
                EmptyView()
            }

            if review.awaitsMyResponse(myLogin: model.currentLogin) {
                StateBadge(text: "Waiting", color: .yellow)
            }
        }
    }
```

A `@ViewBuilder` body emits both, so the caller's existing `HStack` lays them side by side.
If the call site does not already stack its children horizontally, wrap the `else` branch
in `HStack(spacing: 4) { … }`.

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify by hand**

Launch the app. Confirm each of these against your own sidebar:

- A review request you have not reviewed shows **New**, and still shows New after you click it. This is the reported bug.
- A review request whose Claude session has finished shows **New** and **Waiting**.
- A PR you approved shows **Approved**, and keeps it.
- Your own PRs show Draft, Open, Merged or Closed, and never Waiting.
- Issues are unchanged.

- [ ] **Step 4: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(sidebar): show a Waiting chip for unanswered Claude output"
```

---

## Final Verification

Do not report this work complete without the output of every command below.

- [ ] **Full test suite**

```bash
cd Core && swift test
```

Expected: 462 tests pass, exit code 0. The baseline was 429. Paste the final summary line.

- [ ] **Release build**

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Confirm `approvedByMe` did not drift**

```bash
cd Core && swift test --filter approved
```

Expected: every pre-existing approval test still passes. Task 2 refactored the value's
derivation, and this is the check that it produces the same answer.

- [ ] **Walk the lifecycle on a real PR**

On a review request in your sidebar, confirm the chips change as expected at each step:
open it (stays New), let Claude finish (New + Waiting), post a comment on GitHub and hit
`⇧⌘R` (Reviewed, Waiting gone), approve it (Approved). Report what you actually saw,
including anything that did not match.

## Notes For The Implementer

- Test counts assume the 429 baseline. If `swift test` reports something else, report the
  real number and carry the delta through.
- Task 4 rewrites `SidebarStatusTests.swift`. Read the "Replaced Tests" section first so
  you understand why, and do not simply delete the four tests that fail.
- `MyReviewState` has a case called `none`, and it is stored in an `Optional`. Swift needs
  `case .none, .some(.none)` to match both an absent value and the enum case. Watch for a
  warning here — the compiler can silently pick one meaning.
- Task 3 tells you to check whether `WorkItem` has a hand-written `init(from:)`. It has an
  explicit `CodingKeys` enum at line 33, so verify before assuming synthesis.
