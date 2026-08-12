# Resource Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap PRPilot's live Claude sessions and web views, refresh only what the user looks at, and stop Spotlight indexing the worktree root.

**Architecture:** Every decision lives in a pure, `Sendable` type in `AppCore` or `WorktreeKit` that takes plain values and returns plain values. `AppModel`, `WebViewCache`, and `PRPilotApp` call those types and perform the side effects. This keeps the eviction and scheduling logic testable without a PTY, a `WKWebView`, or a network call.

**Tech Stack:** Swift 6, macOS 14 minimum, SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Swift Package Manager for `Core/`, XcodeGen for the app target.

**Spec:** `docs/superpowers/specs/2026-08-12-resource-limits-design.md`

## Global Constraints

- Swift tools version 6.0, platform `.macOS(.v14)`. See `Core/Package.swift`.
- Test framework is Swift Testing. Never add XCTest.
- New `Settings` fields decode through `decodeIfPresent` with a default. This matches `Core/Sources/PRPilotModels/Settings.swift:108` and keeps existing `store.json` files readable.
- `maxLiveClaudeSessions` default is 5. `maxLiveWebViews` default is 8.
- Never write comments unless this plan shows them. The codebase comments the *why*, not the *what*.
- Separate blocks of logic with blank lines.
- Baseline before any change: 384 tests pass, exit code 0. Never reduce that count.
- Full test command, run from the repo root: `cd Core && swift test`

## Deviations From The Spec

Two, both simplifications. Read them before starting. Reject either one and the affected task changes.

1. **The worktree migration is not guarded by `schemaVersion`.** The spec asked for a version bump. That cannot work: `ReviewStore.loadOrCreate` at `Core/Sources/ReviewStore/ReviewStore.swift:77` already bumps a stale `schemaVersion` and rewrites the file during `init`, before `AppModel` ever runs. The flag would be consumed too early. Instead the migration is idempotent by condition — it runs when the legacy directory exists, and after the rename it cannot run again.

2. **Focused refresh uses a most-stale-first batch, with no separate stale threshold.** The spec described a threshold plus a batch. The batch alone produces the same round-robin behaviour with one knob instead of two.

## Verified Facts

These were tested, not assumed. Do not re-litigate them.

- `git -C <movedWorktree> worktree repair` fixes the clone's reverse link after the worktree root is renamed. Proven on git 2.53.0: the command printed `repair: gitdir incorrect: …`, then `git status` and `git worktree list` both worked against the new path. The clone path is *not* needed — git finds it from the worktree's own `.git` file, which the rename does not touch.
- A directory whose name ends in `.noindex` is not indexed by Spotlight. A `.metadata_never_index` marker file does **not** work — a probe file beside one was still returned by `mdfind`.
- `AppModelTests` launches real `ClaudeSession` objects with `claudePath: "/usr/bin/true"` and a `StubWorktreeProvider`. Session eviction is therefore testable end-to-end at the `AppModel` level.

## File Structure

**Create:**

- `Core/Sources/AppCore/SessionBudget.swift` — decides which Claude sessions to evict
- `Core/Sources/AppCore/WebViewBudget.swift` — decides which web views to evict
- `Core/Sources/AppCore/RefreshScheduler.swift` — decides which items to refresh this cycle
- `Core/Sources/AppCore/WorktreeOrphanScanner.swift` — decides which worktree directories are orphans
- `Core/Sources/WorktreeKit/WorktreeLayout.swift` — the worktree root name and the path rewrite
- `Core/Tests/AppCoreTests/SessionBudgetTests.swift`
- `Core/Tests/AppCoreTests/WebViewBudgetTests.swift`
- `Core/Tests/AppCoreTests/RefreshSchedulerTests.swift`
- `Core/Tests/AppCoreTests/WorktreeOrphanScannerTests.swift`
- `Core/Tests/WorktreeKitTests/WorktreeLayoutTests.swift`

**Modify:**

- `Core/Sources/PRPilotModels/Settings.swift` — two new fields
- `Core/Sources/AppCore/AppModel.swift` — eviction, capped prewarm, focused refresh, manual refresh, migration, pruning
- `Core/Sources/WorktreeKit/WorktreeManager.swift` — use `WorktreeLayout`, add `repairWorktree`
- `Core/Sources/WorktreeKit/WorktreeManaging.swift` — add `repairWorktree` to the protocol
- `App/WebViewCache.swift` — activation order and eviction
- `App/PRPilotApp.swift` — cap the launch loop, add the Refresh All command
- `App/ContentView.swift` — pass the selection to the web view cache
- `App/SettingsView.swift` — two steppers
- `Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift` — settings decode tests
- `Core/Tests/AppCoreTests/AppModelTests.swift` — eviction and refresh integration tests
- `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift` — repair test

---

### Task 1: Settings fields for the two caps

**Files:**
- Modify: `Core/Sources/PRPilotModels/Settings.swift`
- Test: `Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `Settings.maxLiveClaudeSessions: Int` (default 5), `Settings.maxLiveWebViews: Int` (default 8)

- [ ] **Step 1: Write the failing tests**

Append to `Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift`:

```swift
@Test func settingsDefaultToDocumentedCaps() {
    #expect(Settings.default.maxLiveClaudeSessions == 5)
    #expect(Settings.default.maxLiveWebViews == 8)
}

@Test func settingsWithoutCapsDecodeToDefaults() throws {
    let json = """
    {
      "managedRoot": "/tmp/prpilot",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

    #expect(decoded.maxLiveClaudeSessions == 5)
    #expect(decoded.maxLiveWebViews == 8)
}

@Test func settingsRoundTripPreservesCaps() throws {
    var settings = Settings.default
    settings.maxLiveClaudeSessions = 2
    settings.maxLiveWebViews = 3

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Settings.self, from: encoder.encode(settings))

    #expect(decoded.maxLiveClaudeSessions == 2)
    #expect(decoded.maxLiveWebViews == 3)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter Caps`
Expected: compile failure — `value of type 'Settings' has no member 'maxLiveClaudeSessions'`

- [ ] **Step 3: Add the two fields**

In `Core/Sources/PRPilotModels/Settings.swift`, after the `issuePromptTemplate` property declaration:

```swift
    /// Live `claude` child processes allowed at once. Each costs roughly 550 MB, so an
    /// uncapped one-per-item spread exhausts swap on a large work list.
    public var maxLiveClaudeSessions: Int
    /// Live web views allowed at once. Each holds its own WebContent process.
    public var maxLiveWebViews: Int
```

Add to the memberwise `init` parameter list, immediately after `issuePromptTemplate`:

```swift
        maxLiveClaudeSessions: Int = 5,
        maxLiveWebViews: Int = 8
```

Add to the `init` body, after `self.issuePromptTemplate = issuePromptTemplate`:

```swift
        self.maxLiveClaudeSessions = maxLiveClaudeSessions
        self.maxLiveWebViews = maxLiveWebViews
```

Add to `init(from:)`, after the `issuePromptTemplate` decode:

```swift
        maxLiveClaudeSessions = try c.decodeIfPresent(Int.self, forKey: .maxLiveClaudeSessions) ?? 5
        maxLiveWebViews = try c.decodeIfPresent(Int.self, forKey: .maxLiveWebViews) ?? 8
```

`CodingKeys` is synthesized from the stored properties, so both new keys appear automatically.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter Caps`
Expected: 3 tests pass

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 387 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PRPilotModels/Settings.swift Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift
git commit -m "feat(settings): add live session and web view caps"
```

---

### Task 2: `SessionBudget`

**Files:**
- Create: `Core/Sources/AppCore/SessionBudget.swift`
- Test: `Core/Tests/AppCoreTests/SessionBudgetTests.swift`

**Interfaces:**
- Consumes: `ClaudeStatus` from `ClaudeSessionKit`
- Produces: `SessionBudget.Candidate(id:lastOpenedAt:status:)` and `SessionBudget.evictions(candidates:cap:selectedID:) -> [String]`, returning ids oldest first

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/SessionBudgetTests.swift`:

```swift
import Testing
import Foundation
import ClaudeSessionKit
@testable import AppCore

private func candidate(
    _ id: String,
    minutesAgo: Int,
    status: ClaudeStatus = .idle(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil)
) -> SessionBudget.Candidate {
    SessionBudget.Candidate(
        id: id,
        lastOpenedAt: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60),
        status: status
    )
}

@Test func budgetEvictsNothingUnderTheCap() {
    let victims = SessionBudget.evictions(
        candidates: [candidate("a", minutesAgo: 1), candidate("b", minutesAgo: 2)],
        cap: 5,
        selectedID: "a"
    )

    #expect(victims.isEmpty)
}

@Test func budgetEvictsTheOldestBeyondTheCap() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["oldest", "middle"])
}

@Test func budgetNeverEvictsTheSelectedItem() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3),
        ],
        cap: 2,
        selectedID: "oldest"
    )

    #expect(victims == ["middle"])
}

@Test func budgetSkipsAWorkingSessionAndTakesTheNextCandidate() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3, status: .working),
        ],
        cap: 2,
        selectedID: "newest"
    )

    #expect(victims == ["middle"])
}

@Test func budgetSkipsAStartingSession() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("oldest", minutesAgo: 2, status: .starting),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims.isEmpty)
}

@Test func budgetStaysOverTheCapWhenEveryCandidateIsProtected() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("a", minutesAgo: 1, status: .working),
            candidate("b", minutesAgo: 2, status: .working),
            candidate("c", minutesAgo: 3, status: .working),
        ],
        cap: 1,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}

@Test func budgetEvictsAwaitingInputAndFailedSessions() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("awaiting", minutesAgo: 2, status: .awaitingInput(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil)),
            candidate("failed", minutesAgo: 3, status: .failed(reason: "boom")),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["failed", "awaiting"])
}

@Test func budgetEvictsNothingForANonPositiveCap() {
    let victims = SessionBudget.evictions(
        candidates: [candidate("a", minutesAgo: 1)],
        cap: 0,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter SessionBudget`
Expected: compile failure — `cannot find 'SessionBudget' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/AppCore/SessionBudget.swift`:

```swift
import Foundation
import ClaudeSessionKit

/// Chooses which live Claude sessions to shut down once the cap is exceeded.
///
/// The cap is a strong target, not a hard ceiling: a session that is mid-turn is never
/// killed, because SIGTERM would throw away work the user is waiting for. When every
/// candidate is protected the budget returns nothing and the session count stays high.
public enum SessionBudget {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let lastOpenedAt: Date
        public let status: ClaudeStatus

        public init(id: String, lastOpenedAt: Date, status: ClaudeStatus) {
            self.id = id
            self.lastOpenedAt = lastOpenedAt
            self.status = status
        }
    }

    /// Returns the ids to evict, oldest first.
    public static func evictions(
        candidates: [Candidate],
        cap: Int,
        selectedID: String?
    ) -> [String] {
        guard cap > 0, candidates.count > cap else { return [] }

        let newestFirst = candidates.sorted { left, right in
            if left.lastOpenedAt == right.lastOpenedAt { return left.id < right.id }
            return left.lastOpenedAt > right.lastOpenedAt
        }
        let overflow = candidates.count - cap

        var victims: [String] = []
        for candidate in newestFirst.reversed() {
            if victims.count == overflow { break }
            if candidate.id == selectedID { continue }
            if isProtected(candidate.status) { continue }
            victims.append(candidate.id)
        }
        return victims
    }

    private static func isProtected(_ status: ClaudeStatus) -> Bool {
        switch status {
        case .starting, .working:
            return true
        case .awaitingInput, .idle, .ready, .failed:
            return false
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter SessionBudget`
Expected: 8 tests pass

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/AppCore/SessionBudget.swift Core/Tests/AppCoreTests/SessionBudgetTests.swift
git commit -m "feat(appcore): add SessionBudget eviction policy"
```

---

### Task 3: Evict Claude sessions in `AppModel`

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `SessionBudget.evictions(candidates:cap:selectedID:)` from Task 2, `Settings.maxLiveClaudeSessions` from Task 1
- Produces: `AppModel.enforceSessionBudget()`, internal so tests can call it; `AppModel.evictClaudeSession(for:)`, private

**Why a separate teardown.** The existing `terminateClaudeSession(for:)` at `AppModel.swift:754` also clears `prStatuses`, `rebaseStates`, and `pushability`. Those are GitHub facts about the PR, not session state. Reusing it would blank the CI and review chips in the sidebar every time a session was evicted. Eviction needs its own narrower teardown.

- [ ] **Step 1: Write the failing tests**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
private func cappedReview(_ suffix: String, number: Int, openedMinutesAgo: Int) -> WorkItem {
    WorkItem(
        id: "item-\(suffix)",
        title: "item \(suffix)",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "branch-\(suffix)",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: number,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/\(number)")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(openedMinutesAgo) * 60)
    )
}

private func cappedModel(store: ReviewStore) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

@Test @MainActor func sessionBudgetEvictsTheOldestSessionBeyondTheCap() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let middle = cappedReview("middle", number: 2, openedMinutesAgo: 2)
    let oldest = cappedReview("oldest", number: 3, openedMinutesAgo: 3)
    for item in [newest, middle, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, middle, newest] {
        await model.ensureClaudeSession(for: item)
    }

    model.enforceSessionBudget()

    #expect(model.claudeSessions.count == 2)
    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.claudeSessions[middle.id] != nil)
    #expect(model.claudeSessions[newest.id] != nil)
}

@Test @MainActor func sessionEvictionKeepsThePersistedSessionIDForResume() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureClaudeSession(for: item)
    }
    let persistedBefore = model.reviews.first { $0.id == oldest.id }?.claudeSessionID

    model.enforceSessionBudget()

    let stored = await store.item(id: oldest.id)?.claudeSessionID

    #expect(persistedBefore != nil)
    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.reviews.first { $0.id == oldest.id }?.claudeSessionID == persistedBefore)
    #expect(stored == persistedBefore)
}

@Test @MainActor func sessionEvictionKeepsTheGitHubStatusChips() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureClaudeSession(for: item)
    }
    model.setPRStatusForTesting(
        PRStatus(ci: .passing, isBehind: false, readiness: .reviewRequired),
        for: oldest.id
    )

    model.enforceSessionBudget()

    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.prStatuses[oldest.id] != nil)
}

@Test @MainActor func sessionBudgetProtectsAWorkingSession() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureClaudeSession(for: item)
    }
    let now = Date()
    model.handleTranscriptEvent(reviewID: oldest.id, at: now, snippet: "working", turnCompleted: false)
    model.recomputeStatus(for: oldest.id, now: now)

    model.enforceSessionBudget()

    #expect(model.claudeSessions[oldest.id] != nil)
}
```

`PRStatus` has no public test seam today. Add one in Step 3.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter sessionBudget`
Expected: compile failure — `value of type 'AppModel' has no member 'enforceSessionBudget'`

- [ ] **Step 3: Write the implementation**

In `Core/Sources/AppCore/AppModel.swift`, add after `terminateClaudeSession(for:)` (which ends at line 771):

```swift
    /// Shuts a session down to reclaim its process, and nothing more. Unlike
    /// `terminateClaudeSession`, this keeps `prStatuses`, `rebaseStates` and `pushability`,
    /// which describe the PR on GitHub rather than the session, and keeps the persisted
    /// `claudeSessionID` so the next open resumes instead of starting over.
    private func evictClaudeSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePreparing.remove(id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        sessionLaunchedIsDark.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        lastEventWasTurnCompletion.removeValue(forKey: id)
        workflowPendingForSession.removeValue(forKey: id)
        notifiedAwaitingForSession.remove(id)
    }

    func enforceSessionBudget() {
        let candidates: [SessionBudget.Candidate] = claudeSessions.keys.compactMap { id in
            guard let review = reviews.first(where: { $0.id == id }) else { return nil }
            return SessionBudget.Candidate(
                id: id,
                lastOpenedAt: review.lastOpenedAt ?? review.addedAt,
                status: claudeStatuses[id] ?? .starting
            )
        }
        let victims = SessionBudget.evictions(
            candidates: candidates,
            cap: settings.maxLiveClaudeSessions,
            selectedID: selection
        )
        for id in victims {
            evictClaudeSession(for: id)
        }
    }

    func setPRStatusForTesting(_ status: PRStatus, for id: String) {
        prStatuses[id] = status
    }
```

A session with no entry in `claudeStatuses` has not reported yet, so it defaults to `.starting` and is protected. `tickAllActiveStatuses` gives every live session a status within five seconds.

Then call it at the two points the spec names. At the end of `ensureClaudeSession(for:forceFresh:)`, after the session is stored in `claudeSessions`, add:

```swift
        enforceSessionBudget()
```

And in `markReviewOpened(_:)` at line 838, after `reviews = await store.allItems()`, add:

```swift
        enforceSessionBudget()
```

`markReviewOpened` is the selection-change hook — `App/ContentView.swift:169` calls it from `onChange(of: model.selection)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter sessionBudget`
Expected: 3 tests pass

Run: `cd Core && swift test --filter sessionEviction`
Expected: 2 tests pass

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 392 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): evict least-recently-opened Claude sessions above the cap"
```

---

### Task 4: Cap the Claude prewarm at launch

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift:810`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `Settings.maxLiveClaudeSessions` from Task 1
- Produces: no new API — `prewarmClaude()` keeps its signature

**Why.** This loop is the measured cause. It iterates every non-disabled item and starts one `claude` per item, which reached 7.0 GB across 13 processes in three minutes on a 36-item store. Task 3's eviction would fight it forever: prewarm starts number 6, eviction kills number 1, prewarm starts number 7. The loop must respect the cap itself.

- [ ] **Step 1: Write the failing test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
@Test @MainActor func prewarmStopsAtTheSessionCap() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...5 {
        try await store.upsertItem(cappedReview("pw\(index)", number: index, openedMinutesAgo: index))
    }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.prewarmClaudeAndWait()

    #expect(model.claudeSessions.count == 2)
}

@Test @MainActor func prewarmStartsTheMostRecentlyOpenedItemsFirst() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...4 {
        try await store.upsertItem(cappedReview("pw\(index)", number: index, openedMinutesAgo: index))
    }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.prewarmClaudeAndWait()

    #expect(model.claudeSessions["item-pw1"] != nil)
    #expect(model.claudeSessions["item-pw2"] != nil)
    #expect(model.claudeSessions["item-pw3"] == nil)
    #expect(model.claudeSessions["item-pw4"] == nil)
}
```

`item-pw1` was opened one minute ago and `item-pw4` four minutes ago, so `pw1` and `pw2` are the two most recent.

The existing `prewarmClaude()` returns immediately and does its work in a detached `Task`, which a test cannot await. Step 3 extracts the body into an awaitable method and keeps `prewarmClaude()` as the fire-and-forget wrapper the app calls.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter prewarm`
Expected: compile failure — `value of type 'AppModel' has no member 'prewarmClaudeAndWait'`

- [ ] **Step 3: Write the implementation**

Replace `prewarmClaude()` at `Core/Sources/AppCore/AppModel.swift:810` with:

```swift
    public func prewarmClaude() {
        Task(priority: .background) { [weak self] in
            await self?.prewarmClaudeAndWait()
        }
    }

    /// Warms the most recently opened items up to the session cap. Warming every item
    /// starts one `claude` process per item, which exhausts memory on a large work list.
    func prewarmClaudeAndWait() async {
        _ = await claudeExecutable()
        let ordered = reviews
            .filter { !$0.disabled }
            .sorted { left, right in
                (left.lastOpenedAt ?? left.addedAt) > (right.lastOpenedAt ?? right.addedAt)
            }
        for review in ordered {
            if claudeSessions[review.id] != nil { continue }
            guard let clonePath = registeredClonePath(for: review),
                  FileManager.default.fileExists(atPath: clonePath) else { continue }
            if settings.autoLoad {
                if claudeSessions.count >= settings.maxLiveClaudeSessions { continue }
                await ensureClaudeSession(for: review)
            } else {
                let editable = review.category(myLogin: currentLogin) != .reviewRequest
                _ = try? await worktreeProvider.ensureWorktree(
                    for: review,
                    editable: editable,
                    registeredClonePath: clonePath
                )
            }
        }
    }
```

The cap check sits inside the `autoLoad` branch on purpose. The other branch only creates worktrees, which start no process, so the cap must not cut that loop short.

`StubWorktreeProvider` and `StubRegistrar` make `registeredClonePath(for:)` resolve in tests. If it returns `nil` and the tests skip every item, set the clone path the tests need through `StubRegistrar` rather than weakening the assertion.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter prewarm`
Expected: 2 tests pass

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 394 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "fix(appcore): stop prewarm starting one Claude process per work item"
```

---

### Task 5: `WebViewBudget`

**Files:**
- Create: `Core/Sources/AppCore/WebViewBudget.swift`
- Test: `Core/Tests/AppCoreTests/WebViewBudgetTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `WebViewBudget.evictions(activationOrder:cap:selectedID:) -> [String]`, where `activationOrder` is newest first and the result is oldest first

The logic lives in `AppCore` rather than beside `WebViewCache` because the `App` target has no test target. `App` already imports `AppCore`.

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/WebViewBudgetTests.swift`:

```swift
import Testing
@testable import AppCore

@Test func webViewBudgetEvictsNothingUnderTheCap() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["a", "b"],
        cap: 8,
        selectedID: "a"
    )

    #expect(victims.isEmpty)
}

@Test func webViewBudgetEvictsTheOldestBeyondTheCap() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["newest", "middle", "oldest"],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["oldest", "middle"])
}

@Test func webViewBudgetNeverEvictsTheSelectedItem() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["newest", "middle", "oldest"],
        cap: 2,
        selectedID: "oldest"
    )

    #expect(victims == ["middle"])
}

@Test func webViewBudgetEvictsNothingForANonPositiveCap() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["a", "b", "c"],
        cap: 0,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter webViewBudget`
Expected: compile failure — `cannot find 'WebViewBudget' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/AppCore/WebViewBudget.swift`:

```swift
/// Chooses which web views to tear down once the cap is exceeded. A web view has no
/// busy state, so unlike `SessionBudget` the only exemption is the selected item.
public enum WebViewBudget {
    /// - Parameter activationOrder: item ids, most recently activated first.
    /// - Returns: the ids to evict, oldest first.
    public static func evictions(
        activationOrder: [String],
        cap: Int,
        selectedID: String?
    ) -> [String] {
        guard cap > 0, activationOrder.count > cap else { return [] }

        let overflow = activationOrder.count - cap

        var victims: [String] = []
        for id in activationOrder.reversed() {
            if victims.count == overflow { break }
            if id == selectedID { continue }
            victims.append(id)
        }
        return victims
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter webViewBudget`
Expected: 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/AppCore/WebViewBudget.swift Core/Tests/AppCoreTests/WebViewBudgetTests.swift
git commit -m "feat(appcore): add WebViewBudget eviction policy"
```

---

### Task 6: Evict web views

**Files:**
- Modify: `App/WebViewCache.swift`
- Modify: `App/PRPilotApp.swift:43`
- Modify: `App/ContentView.swift:169`

**Interfaces:**
- Consumes: `WebViewBudget.evictions(activationOrder:cap:selectedID:)` from Task 5, `Settings.maxLiveWebViews` from Task 1
- Produces: `WebViewCache.cap: Int`, `WebViewCache.selectedID: String?`

**Why the launch loop changes too.** `App/PRPilotApp.swift:43` calls `webViewCache.ensure(for:)` for every non-disabled item at launch. That allocates 36 `WKWebView` objects before the user clicks anything.

This task has no automated test. `WKWebView` needs a running app, and the `App` target has no test target. Task 5 covers the decision logic. Step 5 below is a manual check with real process counts.

- [ ] **Step 1: Add the activation order and the cap to `WebViewCache`**

In `App/WebViewCache.swift`, add to the stored properties of `WebViewCache`:

```swift
    /// Item ids, most recently activated first. Drives eviction.
    private var activationOrder: [String] = []
    /// Mirrors `Settings.maxLiveWebViews`. `PRPilotApp` keeps it in step.
    var cap: Int = 8
    /// The selected item is never evicted. `ContentView` keeps it in step.
    var selectedID: String?
```

Add `import AppCore` to the file's imports.

- [ ] **Step 2: Record activations and evict**

Replace the body of `activate(for:)` so it records the activation and enforces the cap. The existing load logic is unchanged; only the two calls around it are new:

```swift
    func activate(for review: WorkItem) {
        recordActivation(review.id)
        enforceBudget()
        guard let url = review.url, let webView = webViews[review.id] else { return }
        if webView.isLoading { return }
        // All webviews share the persistent .default() cookie store, so a session
        // established in one tab is visible to the rest. A tab that loaded while
        // signed out stays on the login page until reloaded — refresh it on
        // revisit so it picks up the now-present session.
        let landedOnLogin = Self.isGitHubAuthPage(webView.url)
        if trackers[review.id]?.didFinishLoad == true && !landedOnLogin { return }
        webView.load(URLRequest(url: url))
    }

    private func recordActivation(_ id: String) {
        activationOrder.removeAll { $0 == id }
        activationOrder.insert(id, at: 0)
    }

    private func enforceBudget() {
        let victims = WebViewBudget.evictions(
            activationOrder: activationOrder,
            cap: cap,
            selectedID: selectedID
        )
        for id in victims {
            remove(reviewID: id)
        }
    }
```

Add to `remove(reviewID:)`, as its first line, so an eviction and an item deletion both keep the order list honest:

```swift
        activationOrder.removeAll { $0 == reviewID }
```

Add to `removeAll()`:

```swift
        activationOrder.removeAll()
```

- [ ] **Step 3: Stop the launch loop pre-creating every web view**

In `App/PRPilotApp.swift`, replace lines 43 to 45:

```swift
                    for review in created.reviews where !review.disabled {
                        _ = webViewCache.ensure(for: review)
                    }
```

with:

```swift
                    webViewCache.cap = created.settings.maxLiveWebViews
```

A web view is now created on first selection, by the `onChange` handler in `ContentView`.

- [ ] **Step 4: Keep the selection in step**

In `App/ContentView.swift`, inside the existing `onChange(of: model.selection)` handler at line 164, add before `_ = webViewCache.ensure(for: review)`:

```swift
            webViewCache.selectedID = id
            webViewCache.cap = model.settings.maxLiveWebViews
```

- [ ] **Step 5: Build and verify by hand**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Then launch the app, click through 12 items, and count the web content processes:

```bash
ps -axo comm | grep -c "WebKit.WebContent"
```

Expected: the count rises to roughly 8 plus whatever other apps hold, then stops rising. Before this change it rose with every item opened. Record the number you see in the commit message.

- [ ] **Step 6: Commit**

```bash
git add App/WebViewCache.swift App/PRPilotApp.swift App/ContentView.swift
git commit -m "fix(webview): cap live web views and stop pre-creating one per item"
```

---

### Task 7: Focused refresh

**Files:**
- Create: `Core/Sources/AppCore/RefreshScheduler.swift`
- Create: `Core/Tests/AppCoreTests/RefreshSchedulerTests.swift`
- Modify: `Core/Sources/AppCore/AppModel.swift:958`

**Interfaces:**
- Consumes: nothing
- Produces: `RefreshScheduler.itemsToRefresh(openIDs:selectedID:lastRefreshedAt:batchSize:) -> [String]`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/RefreshSchedulerTests.swift`:

```swift
import Testing
import Foundation
@testable import AppCore

private func stamp(_ secondsAgo: Int) -> Date {
    Date(timeIntervalSince1970: 1_000_000 - Double(secondsAgo))
}

@Test func schedulerAlwaysIncludesTheSelectedItem() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["a", "b", "c"],
        selectedID: "c",
        lastRefreshedAt: ["a": stamp(10), "b": stamp(20), "c": stamp(0)],
        batchSize: 1
    )

    #expect(chosen.first == "c")
}

@Test func schedulerPicksTheMostStaleOthersFirst() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["fresh", "stale", "stalest", "selected"],
        selectedID: "selected",
        lastRefreshedAt: [
            "fresh": stamp(1),
            "stale": stamp(50),
            "stalest": stamp(500),
            "selected": stamp(0),
        ],
        batchSize: 2
    )

    #expect(chosen == ["selected", "stalest", "stale"])
}

@Test func schedulerTreatsNeverRefreshedAsMostStale() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["seen", "never"],
        selectedID: nil,
        lastRefreshedAt: ["seen": stamp(9999)],
        batchSize: 1
    )

    #expect(chosen == ["never"])
}

@Test func schedulerHonoursTheBatchSize() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["a", "b", "c", "d", "e", "f"],
        selectedID: "a",
        lastRefreshedAt: [:],
        batchSize: 4
    )

    #expect(chosen.count == 5)
}

@Test func schedulerSkipsASelectionThatIsNotOpen() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["a", "b"],
        selectedID: "closed",
        lastRefreshedAt: [:],
        batchSize: 4
    )

    #expect(chosen == ["a", "b"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter scheduler`
Expected: compile failure — `cannot find 'RefreshScheduler' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/AppCore/RefreshScheduler.swift`:

```swift
import Foundation

/// Chooses which work items to refresh on a poll cycle.
///
/// Refreshing every open PR each cycle spawns one `gh` per PR. At 18 PRs and a 60 second
/// interval that is a subprocess every three seconds, forever. The selected item still
/// refreshes every cycle; the rest take turns, most stale first.
public enum RefreshScheduler {
    public static func itemsToRefresh(
        openIDs: [String],
        selectedID: String?,
        lastRefreshedAt: [String: Date],
        batchSize: Int
    ) -> [String] {
        var chosen: [String] = []
        if let selectedID, openIDs.contains(selectedID) {
            chosen.append(selectedID)
        }

        let others = openIDs
            .filter { $0 != selectedID }
            .sorted { left, right in
                let leftStamp = lastRefreshedAt[left] ?? .distantPast
                let rightStamp = lastRefreshedAt[right] ?? .distantPast
                if leftStamp == rightStamp { return left < right }
                return leftStamp < rightStamp
            }
        chosen.append(contentsOf: others.prefix(max(0, batchSize)))
        return chosen
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter scheduler`
Expected: 5 tests pass

- [ ] **Step 5: Wire it into `AppModel`**

Add a stored property beside the other private dictionaries near `AppModel.swift:60`:

```swift
    private var lastRefreshedAt: [String: Date] = [:]
    private static let refreshBatchSize = 4
```

Replace `refreshReviewStates()` at `AppModel.swift:958`:

```swift
    func refreshReviewStates() async {
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
        let openIDs = reviews
            .filter { $0.prState != .merged && $0.prState != .closed }
            .map(\.id)
        let ids = RefreshScheduler.itemsToRefresh(
            openIDs: openIDs,
            selectedID: selection,
            lastRefreshedAt: lastRefreshedAt,
            batchSize: Self.refreshBatchSize
        )
        for id in ids {
            await refreshReviewState(for: id)
            lastRefreshedAt[id] = Date()
        }
    }
```

Add to `terminateClaudeSession(for:)`, beside the other per-id cleanups. Leave `evictClaudeSession(for:)` alone — an evicted item is still an open PR and must keep its place in the refresh rotation:

```swift
        lastRefreshedAt.removeValue(forKey: id)
```

- [ ] **Step 6: Add the integration test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
@Test @MainActor func refreshCyclesThroughItemsInsteadOfRefreshingAll() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...10 {
        try await store.upsertItem(cappedReview("rf\(index)", number: index, openedMinutesAgo: index))
    }

    let model = cappedModel(store: store)
    await model.load()
    model.selection = "item-rf1"

    await model.refreshReviewStates()

    #expect(model.refreshedIDsForTesting().count == 5)
    #expect(model.refreshedIDsForTesting().contains("item-rf1"))
}
```

Add the seam to `AppModel`, beside `setPRStatusForTesting`:

```swift
    func refreshedIDsForTesting() -> Set<String> {
        Set(lastRefreshedAt.keys)
    }
```

- [ ] **Step 7: Run the full suite**

Run: `cd Core && swift test`
Expected: 400 tests pass, exit code 0

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/AppCore/RefreshScheduler.swift Core/Tests/AppCoreTests/RefreshSchedulerTests.swift Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "perf(appcore): refresh the selected PR plus a stale batch, not every PR"
```

---

### Task 8: Refresh All command

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Modify: `App/PRPilotApp.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppModel.discoverNow()`, `AppModel.refreshReviewState(for:)`
- Produces: `AppModel.refreshAllNow() async`

**Why `⇧⌘R`.** `⌘R` is taken. `App/WebPane.swift:17` binds it to a reload of the current page.

- [ ] **Step 1: Write the failing test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
@Test @MainActor func refreshAllNowRefreshesEveryOpenItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...10 {
        try await store.upsertItem(cappedReview("ra\(index)", number: index, openedMinutesAgo: index))
    }

    let model = cappedModel(store: store)
    await model.load()

    await model.refreshAllNow()

    #expect(model.refreshedIDsForTesting().count == 10)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Core && swift test --filter refreshAllNow`
Expected: compile failure — `value of type 'AppModel' has no member 'refreshAllNow'`

- [ ] **Step 3: Write the implementation**

Add to `Core/Sources/AppCore/AppModel.swift`, after `refreshReviewStates()`:

```swift
    /// Runs discovery and refreshes every open item, ignoring the staleness batching that
    /// `refreshReviewStates` applies. This is the escape hatch for the poll cycle's lag.
    public func refreshAllNow() async {
        await discoverNow()
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
        let ids = reviews
            .filter { $0.prState != .merged && $0.prState != .closed }
            .map(\.id)
        for id in ids {
            await refreshReviewState(for: id)
            lastRefreshedAt[id] = Date()
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Core && swift test --filter refreshAllNow`
Expected: 1 test passes

- [ ] **Step 5: Add the menu command**

In `App/PRPilotApp.swift`, inside `.commands`, before the existing `CommandMenu("Repositories")`:

```swift
            CommandGroup(after: .toolbar) {
                Button("Refresh All") {
                    guard let model else { return }
                    Task { await model.refreshAllNow() }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(model == nil)
            }
```

- [ ] **Step 6: Build and verify by hand**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Launch the app. Confirm "Refresh All" appears in the View menu with `⇧⌘R`, and that pressing it updates the sidebar chips.

- [ ] **Step 7: Run the full suite**

Run: `cd Core && swift test`
Expected: 401 tests pass, exit code 0

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift App/PRPilotApp.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(app): add Refresh All command on shift-cmd-R"
```

---

### Task 9: Move the worktree root out of Spotlight

**Files:**
- Create: `Core/Sources/WorktreeKit/WorktreeLayout.swift`
- Create: `Core/Tests/WorktreeKitTests/WorktreeLayoutTests.swift`
- Modify: `Core/Sources/WorktreeKit/WorktreeManager.swift` (lines 48, 85, 173, 264)
- Modify: `Core/Sources/WorktreeKit/WorktreeManaging.swift`
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `WorktreeLayout.directoryName`, `WorktreeLayout.legacyDirectoryName`, `WorktreeLayout.directory(managedRoot:)`, `WorktreeLayout.legacyDirectory(managedRoot:)`, `WorktreeLayout.migratedPath(_:managedRoot:) -> String?`, `WorktreeManaging.repairWorktree(worktreePath:) async throws`, `AppModel.migrateWorktreeRoot() async`

**Background, already proven.** Renaming the root leaves each clone's `.git/worktrees/<name>/gitdir` pointing at the old path. `git -C <newWorktreePath> worktree repair` fixes it, and does not need the clone path. The migration is idempotent by condition, not by `schemaVersion` — see the Deviations section.

- [ ] **Step 1: Write the failing `WorktreeLayout` tests**

Create `Core/Tests/WorktreeKitTests/WorktreeLayoutTests.swift`:

```swift
import Testing
@testable import WorktreeKit

@Test func layoutUsesANonIndexedDirectoryName() {
    #expect(WorktreeLayout.directoryName == "worktrees.noindex")
    #expect(WorktreeLayout.legacyDirectoryName == "worktrees")
}

@Test func layoutBuildsBothRoots() {
    #expect(WorktreeLayout.directory(managedRoot: "/m") == "/m/worktrees.noindex")
    #expect(WorktreeLayout.legacyDirectory(managedRoot: "/m") == "/m/worktrees")
}

@Test func layoutRewritesALegacyPath() {
    let rewritten = WorktreeLayout.migratedPath("/m/worktrees/owner-repo-pr1", managedRoot: "/m")

    #expect(rewritten == "/m/worktrees.noindex/owner-repo-pr1")
}

@Test func layoutLeavesAnAlreadyMigratedPathAlone() {
    let rewritten = WorktreeLayout.migratedPath("/m/worktrees.noindex/owner-repo-pr1", managedRoot: "/m")

    #expect(rewritten == nil)
}

@Test func layoutLeavesAPathOutsideTheManagedRootAlone() {
    let rewritten = WorktreeLayout.migratedPath("/elsewhere/worktrees/x", managedRoot: "/m")

    #expect(rewritten == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter layout`
Expected: compile failure — `cannot find 'WorktreeLayout' in scope`

- [ ] **Step 3: Write `WorktreeLayout`**

Create `Core/Sources/WorktreeKit/WorktreeLayout.swift`:

```swift
/// Where managed worktrees live under the managed root.
///
/// The `.noindex` suffix keeps Spotlight out of the tree. A checkout of a large repo runs
/// to gigabytes, and `mds_stores` indexes all of it otherwise. A `.metadata_never_index`
/// marker file was tested and does not work; the directory-name suffix does.
public enum WorktreeLayout {
    public static let directoryName = "worktrees.noindex"
    public static let legacyDirectoryName = "worktrees"

    public static func directory(managedRoot: String) -> String {
        managedRoot + "/" + directoryName
    }

    public static func legacyDirectory(managedRoot: String) -> String {
        managedRoot + "/" + legacyDirectoryName
    }

    /// Returns the new path for a worktree still under the legacy root, or nil when the
    /// path needs no change.
    public static func migratedPath(_ path: String, managedRoot: String) -> String? {
        let legacyPrefix = legacyDirectory(managedRoot: managedRoot) + "/"
        guard path.hasPrefix(legacyPrefix) else { return nil }
        return directory(managedRoot: managedRoot) + "/" + String(path.dropFirst(legacyPrefix.count))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter layout`
Expected: 5 tests pass

- [ ] **Step 5: Use the layout in `WorktreeManager`**

In `Core/Sources/WorktreeKit/WorktreeManager.swift`, replace each of the three occurrences of

```swift
        let worktreesDir = managedRoot + "/worktrees"
```

at lines 48, 173 and 264 with:

```swift
        let worktreesDir = WorktreeLayout.directory(managedRoot: managedRoot)
```

And replace line 85:

```swift
        path.hasPrefix(managedRoot + "/worktrees/")
```

with:

```swift
        path.hasPrefix(WorktreeLayout.directory(managedRoot: managedRoot) + "/")
```

- [ ] **Step 6: Add `repairWorktree` — test first**

Append to `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift`:

```swift
@Test func repairWorktreeFixesAMovedWorktree() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtrepair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let clone = root.appendingPathComponent("clone").path
    let legacyRoot = root.appendingPathComponent("worktrees").path
    let newRoot = root.appendingPathComponent("worktrees.noindex").path
    try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)

    let runner = ProcessCommandRunner()
    _ = try await runner.run(executable: "/usr/bin/git", arguments: ["-C", clone, "init", "-q", "-b", "main"])
    _ = try await runner.run(executable: "/usr/bin/git", arguments: [
        "-C", clone, "-c", "user.email=a@b", "-c", "user.name=a",
        "commit", "-q", "--allow-empty", "-m", "init",
    ])
    _ = try await runner.run(executable: "/usr/bin/git", arguments: [
        "-C", clone, "worktree", "add", "-q", "-b", "feat", legacyRoot + "/wt1",
    ])
    try FileManager.default.moveItem(atPath: legacyRoot, toPath: newRoot)

    let manager = WorktreeManager(runner: runner, gitPath: "/usr/bin/git", managedRoot: root.path)
    try await manager.repairWorktree(worktreePath: newRoot + "/wt1")

    let listed = try await runner.run(executable: "/usr/bin/git", arguments: ["-C", clone, "worktree", "list"])
    #expect(listed.standardOutput.contains(newRoot + "/wt1"))
    #expect(!listed.standardOutput.contains(legacyRoot + "/wt1"))
}
```

Run: `cd Core && swift test --filter repairWorktree`
Expected: compile failure — `value of type 'WorktreeManager' has no member 'repairWorktree'`

- [ ] **Step 7: Implement `repairWorktree`**

Add to `Core/Sources/WorktreeKit/WorktreeManaging.swift`:

```swift
    func repairWorktree(worktreePath: String) async throws
```

Add to `Core/Sources/WorktreeKit/WorktreeManager.swift`, beside `removeWorktree`:

```swift
    /// Re-points a clone's administrative link after its worktree moved on disk. Git finds
    /// the clone from the worktree's own `.git` file, so no clone path is needed.
    public func repairWorktree(worktreePath: String) async throws {
        _ = try await runGit(["-C", worktreePath, "worktree", "repair"])
    }
```

Add the same method to every `WorktreeManaging` conformance in the test targets. `StubWorktreeOps` in `Core/Tests/AppCoreTests/AppModelTests.swift` needs:

```swift
    func repairWorktree(worktreePath: String) async throws {}
```

Run: `cd Core && swift test --filter repairWorktree`
Expected: 1 test passes

- [ ] **Step 8: Write the migration test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
@Test @MainActor func migrationMovesTheWorktreeRootAndRewritesPaths() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let stored = await store.item(id: item.id)?.worktreePath

    #expect(FileManager.default.fileExists(atPath: expected))
    #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("worktrees").path))
    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == expected)
    #expect(stored == expected)
}

@Test @MainActor func migrationIsANoOpOnASecondRun() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()
    let afterFirst = model.reviews.first { $0.id == item.id }?.worktreePath
    await model.migrateWorktreeRoot()

    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == afterFirst)
}
```

Run: `cd Core && swift test --filter migration`
Expected: compile failure — `value of type 'AppModel' has no member 'migrateWorktreeRoot'`

- [ ] **Step 9: Implement the migration**

Add to `Core/Sources/AppCore/AppModel.swift`:

```swift
    /// Moves the managed worktree root to a `.noindex` name so Spotlight stops indexing it,
    /// then repairs each clone's link to its moved worktree.
    ///
    /// Idempotent by condition rather than by a schema flag: `ReviewStore.loadOrCreate`
    /// bumps a stale `schemaVersion` during its own init, before this runs, so a flag would
    /// already be consumed. Once the legacy directory is gone this does nothing.
    func migrateWorktreeRoot() async {
        let managedRoot = settings.managedRoot
        let legacy = WorktreeLayout.legacyDirectory(managedRoot: managedRoot)
        let destination = WorktreeLayout.directory(managedRoot: managedRoot)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy) else { return }
        guard !fileManager.fileExists(atPath: destination) else { return }

        do {
            try fileManager.moveItem(atPath: legacy, toPath: destination)
        } catch {
            errorMessage = "Could not move the worktree directory: \(error)"
            return
        }

        for review in reviews {
            guard let old = review.worktreePath,
                  let new = WorktreeLayout.migratedPath(old, managedRoot: managedRoot) else { continue }
            var updated = review
            updated.worktreePath = new
            try? await store.upsertItem(updated)
            try? await worktreeOps.repairWorktree(worktreePath: new)
        }
        reviews = await store.allItems()
    }
```

Call it from `load()`, immediately after `settings = await store.settings()`:

```swift
        await migrateWorktreeRoot()
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `cd Core && swift test --filter migration`
Expected: 2 tests pass

- [ ] **Step 11: Run the full suite**

Run: `cd Core && swift test`
Expected: 409 tests pass, exit code 0

- [ ] **Step 12: Commit**

```bash
git add Core/Sources/WorktreeKit Core/Tests/WorktreeKitTests Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "perf(worktree): move the worktree root to a .noindex directory"
```

---

### Task 10: Prune orphaned worktrees

**Files:**
- Create: `Core/Sources/AppCore/WorktreeOrphanScanner.swift`
- Create: `Core/Tests/AppCoreTests/WorktreeOrphanScannerTests.swift`
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Modify: `App/PRPilotApp.swift`

**Interfaces:**
- Consumes: `WorktreeLayout.directory(managedRoot:)` from Task 9
- Produces: `WorktreeOrphanScanner.orphanPaths(directoryNames:rootPath:liveWorktreePaths:) -> [String]`, `AppModel.orphanedWorktreePaths() -> [String]`, `AppModel.pruneOrphanedWorktrees() async -> Int`

- [ ] **Step 1: Write the failing scanner tests**

Create `Core/Tests/AppCoreTests/WorktreeOrphanScannerTests.swift`:

```swift
import Testing
@testable import AppCore

@Test func scannerFindsDirectoriesWithNoMatchingItem() {
    let orphans = WorktreeOrphanScanner.orphanPaths(
        directoryNames: ["owner-repo-pr1", "owner-repo-pr2", "owner-repo-pr3"],
        rootPath: "/m/worktrees.noindex",
        liveWorktreePaths: ["/m/worktrees.noindex/owner-repo-pr2"]
    )

    #expect(orphans == ["/m/worktrees.noindex/owner-repo-pr1", "/m/worktrees.noindex/owner-repo-pr3"])
}

@Test func scannerFindsNothingWhenEveryDirectoryIsLive() {
    let orphans = WorktreeOrphanScanner.orphanPaths(
        directoryNames: ["a", "b"],
        rootPath: "/m/worktrees.noindex",
        liveWorktreePaths: ["/m/worktrees.noindex/a", "/m/worktrees.noindex/b"]
    )

    #expect(orphans.isEmpty)
}

@Test func scannerIgnoresDotDirectories() {
    let orphans = WorktreeOrphanScanner.orphanPaths(
        directoryNames: [".DS_Store", "a"],
        rootPath: "/m/worktrees.noindex",
        liveWorktreePaths: []
    )

    #expect(orphans == ["/m/worktrees.noindex/a"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter scanner`
Expected: compile failure — `cannot find 'WorktreeOrphanScanner' in scope`

- [ ] **Step 3: Write the scanner**

Create `Core/Sources/AppCore/WorktreeOrphanScanner.swift`:

```swift
/// Finds worktree directories that no work item points at. Removing a work item does not
/// remove its worktree, so the managed root accumulates checkouts of several gigabytes each.
public enum WorktreeOrphanScanner {
    public static func orphanPaths(
        directoryNames: [String],
        rootPath: String,
        liveWorktreePaths: Set<String>
    ) -> [String] {
        directoryNames
            .filter { !$0.hasPrefix(".") }
            .map { rootPath + "/" + $0 }
            .filter { !liveWorktreePaths.contains($0) }
            .sorted()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter scanner`
Expected: 3 tests pass

- [ ] **Step 5: Write the failing `AppModel` test**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
@Test @MainActor func pruneRemovesOnlyTheOrphanedWorktrees() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtprune-\(UUID().uuidString)", isDirectory: true)
    let root = managedRoot.appendingPathComponent("worktrees.noindex")
    for name in ["live", "orphan-a", "orphan-b"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("live", number: 1, openedMinutesAgo: 1)
    item.worktreePath = root.appendingPathComponent("live").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.orphanedWorktreePaths().count == 2)

    let removed = await model.pruneOrphanedWorktrees()

    #expect(removed == 2)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("live").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-a").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-b").path))
}
```

Run: `cd Core && swift test --filter pruneRemoves`
Expected: compile failure — `value of type 'AppModel' has no member 'orphanedWorktreePaths'`

- [ ] **Step 6: Implement pruning**

Add to `Core/Sources/AppCore/AppModel.swift`:

```swift
    public func orphanedWorktreePaths() -> [String] {
        let root = WorktreeLayout.directory(managedRoot: settings.managedRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let live = Set(reviews.compactMap(\.worktreePath))
        return WorktreeOrphanScanner.orphanPaths(
            directoryNames: names,
            rootPath: root,
            liveWorktreePaths: live
        )
    }

    /// Deletes worktree directories no work item points at. Returns how many went.
    @discardableResult
    public func pruneOrphanedWorktrees() async -> Int {
        var removed = 0
        for path in orphanedWorktreePaths() {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed += 1
            } catch {
                errorMessage = "Could not remove \(path): \(error)"
            }
        }
        return removed
    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd Core && swift test --filter pruneRemoves`
Expected: 1 test passes

- [ ] **Step 8: Add the menu command**

In `App/PRPilotApp.swift`, add a state property beside the others:

```swift
    @State private var pruneCount: Int?
```

Add to the existing `CommandMenu("Repositories")`:

```swift
                Button("Prune Orphaned Worktrees…") {
                    guard let model else { return }
                    pruneCount = model.orphanedWorktreePaths().count
                }
                .disabled(model == nil)
```

Add to the `Group` inside `WindowGroup`, beside the existing `.sheet`:

```swift
                        .confirmationDialog(
                            "Delete \(pruneCount ?? 0) orphaned worktree directories?",
                            isPresented: Binding(
                                get: { pruneCount != nil },
                                set: { if !$0 { pruneCount = nil } }
                            )
                        ) {
                            Button("Delete", role: .destructive) {
                                guard let model else { return }
                                Task { await model.pruneOrphanedWorktrees() }
                                pruneCount = nil
                            }
                            Button("Cancel", role: .cancel) { pruneCount = nil }
                        } message: {
                            Text("This removes worktree checkouts no work item points at. Local commits in those directories are lost.")
                        }
```

- [ ] **Step 9: Build and verify by hand**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Launch the app. Open Repositories → Prune Orphaned Worktrees. Confirm the count matches, then cancel. Do not confirm the deletion during this check — the user has 13 real orphans and should decide.

- [ ] **Step 10: Run the full suite**

Run: `cd Core && swift test`
Expected: 413 tests pass, exit code 0

- [ ] **Step 11: Commit**

```bash
git add Core/Sources/AppCore/WorktreeOrphanScanner.swift Core/Tests/AppCoreTests/WorktreeOrphanScannerTests.swift Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift App/PRPilotApp.swift
git commit -m "feat(worktree): add a command to prune orphaned worktrees"
```

---

### Task 11: Settings UI for the caps

**Files:**
- Modify: `App/SettingsView.swift`

**Interfaces:**
- Consumes: `Settings.maxLiveClaudeSessions`, `Settings.maxLiveWebViews` from Task 1
- Produces: nothing

No automated test. The `App` target has no test target, and Task 1 covers the model.

- [ ] **Step 1: Add the state**

In `App/SettingsView.swift`, beside `@State private var autoLoad = false`:

```swift
    @State private var maxLiveClaudeSessions = 5
    @State private var maxLiveWebViews = 8
```

- [ ] **Step 2: Add the section**

After the existing `Section("Poll interval")` block:

```swift
            Section("Resource limits") {
                Stepper(value: $maxLiveClaudeSessions, in: 1...20) {
                    Text("\(maxLiveClaudeSessions) live Claude sessions")
                }
                Stepper(value: $maxLiveWebViews, in: 1...30) {
                    Text("\(maxLiveWebViews) live GitHub pages")
                }
                Text("Each Claude session is a process of roughly 550 MB. Each GitHub page holds its own web content process. Least-recently-opened items are closed above these limits, and reopen where they left off. A session that is mid-turn is never closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Load and commit the values**

In `.onAppear`, after `autoLoad = model.settings.autoLoad`:

```swift
            maxLiveClaudeSessions = model.settings.maxLiveClaudeSessions
            maxLiveWebViews = model.settings.maxLiveWebViews
```

Add two `onChange` modifiers beside the existing ones:

```swift
        .onChange(of: maxLiveClaudeSessions) { _, _ in commit() }
        .onChange(of: maxLiveWebViews) { _, _ in commit() }
```

In `commit()`, after `updated.autoLoad = autoLoad`:

```swift
        updated.maxLiveClaudeSessions = maxLiveClaudeSessions
        updated.maxLiveWebViews = maxLiveWebViews
```

- [ ] **Step 4: Build and verify by hand**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Launch the app, open Settings, change both steppers, quit and relaunch. Confirm the values persist.

- [ ] **Step 5: Commit**

```bash
git add App/SettingsView.swift
git commit -m "feat(settings): expose the session and web view caps"
```

---

## Final Verification

Do not report this work complete without the output of every command below.

- [ ] **Full test suite**

```bash
cd Core && swift test
```

Expected: 413 tests pass, exit code 0. The baseline was 384. Paste the final summary line.

- [ ] **Release build**

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Measure against the baseline**

Launch the app, wait one minute, click through 12 items, then leave it idle one minute. Run:

```bash
app=$(pgrep -f "PRPilot.app/Contents/MacOS/PR Pilot" | head -1)
ps -axo pid,ppid,rss,command | awk -v a="$app" '$2==a' | grep claude | wc -l
ps -axo rss,command | grep "local/bin/claude" | grep -v grep | awk '{s+=$1} END {printf "claude total: %.1f GB\n", s/1048576}'
ps -axo comm | grep -c "WebKit.WebContent"
sysctl vm.swapusage
```

Expected, against the measured baseline of 13 processes / 7.0 GB / 22 web content processes:
- Claude child count stops at the cap, 5 by default
- Claude total near 2.8 GB
- WebContent count stops rising past roughly 8 plus other apps

Report the real numbers. If they miss the prediction, say so — the spec's table is a prediction, not a result.

- [ ] **Confirm Spotlight exclusion**

```bash
mdfind -onlyin ~/Library/Application\ Support/PRPilot/worktrees.noindex "go.mod" | head -3
```

Expected: no output. Any output means the exclusion failed.

- [ ] **Confirm the worktrees still work**

```bash
for w in ~/Library/Application\ Support/PRPilot/worktrees.noindex/*/; do
  git -C "$w" status --short >/dev/null 2>&1 || echo "BROKEN: $w"
done
echo "check complete"
```

Expected: `check complete` with no `BROKEN` lines.

---

## Notes For The Implementer

- Task 3's `setPRStatusForTesting` and Task 7's `refreshedIDsForTesting` are internal, not public. `AppCoreTests` uses `@testable import AppCore`, so internal is enough. Do not make them public.
- Task 9 renames a directory holding 11 GB of the user's checkouts. `moveItem` within one volume is a rename and is fast, but confirm the managed root and the destination are on the same volume before trusting that.
- If `swift test` reports a different baseline than 384, report the real number and carry the delta through the expected counts.
