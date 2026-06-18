# Triage Trio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three sidebar-triage improvements to PRPilot as one feature: an "awaiting input" Claude status (and sharper notification), sidebar search + All/Active/Awaiting filter pills, and per-row ahead/behind chips.

**Architecture:** A new `ClaudeStatus.awaitingInput` case driven by whether the latest transcript event completed a turn; AppModel tracks that flag, retargets the notification gate to awaiting-input (re-armed per turn), and stores ahead/behind counts on `Pushability`. A pure `sidebarItemMatches` in `PRPilotModels` powers a search-field + pills header in `ContentView`, which also renders the new dot color and ahead/behind chips.

**Tech Stack:** Swift 6, SwiftPM (`Core/`), Xcode app (`PRPilot.xcodeproj`, XcodeGen from `project.yml`), swift-testing, SwiftTerm.

## Global Constraints

- swift-tools-version 6.0; platform macOS 14.
- `.awaitingInput` fires immediately when the latest transcript event completed a turn (`end_turn`), regardless of the idle threshold. `.idle` is retained for "running, quiet, last event NOT a turn completion".
- Notification fires on `working → awaitingInput`, re-armed when the session returns to `.working` (one pending notification per session, one per completed turn).
- Search match is case-insensitive substring over: title, `owner/repo`, author, headBranch, `#number`. Filter: `.all` = all; `.active` = working or awaiting; `.awaiting` = awaiting only. Filter state is view-local (not persisted).
- Ahead/behind chips show only for items with a `Pushability` entry (editable branch worktrees), distinct from the existing GitHub "behind" badge.
- No GitHub writes. No schema-version bump (no persisted-model changes).
- Commit messages: NO AI/Claude attribution; use `--no-verify`.
- Core test command: `swift test --package-path Core --filter <name>` (run from the active worktree root). App build: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`.

---

### Task 1: `ClaudeStatus.awaitingInput` + reader logic

**Files:**
- Modify: `Core/Sources/ClaudeSessionKit/ClaudeStatus.swift`
- Modify: `Core/Sources/ClaudeSessionKit/ClaudeStatusReader.swift`
- Test: `Core/Tests/ClaudeSessionKitTests/ClaudeStatusReaderTests.swift`

**Interfaces:**
- Produces:
  - `ClaudeStatus.awaitingInput(since: Date, lastVerdictSnippet: String?)`
  - `ClaudeStatusReader.status(processState:lastEventAt:lastVerdictSnippet:now:lastEventWasTurnCompletion:)` — new trailing parameter `lastEventWasTurnCompletion: Bool = false`.

- [ ] **Step 1: Write the failing tests**

Add to `Core/Tests/ClaudeSessionKitTests/ClaudeStatusReaderTests.swift`:

```swift
@Test func completedTurnYieldsAwaitingInputEvenWhenStale() {
    let reader = ClaudeStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: "done",
                          now: t.addingTimeInterval(600), lastEventWasTurnCompletion: true)
    #expect(s == .awaitingInput(since: t, lastVerdictSnippet: "done"))
}

@Test func recentNonCompletedIsWorking() {
    let reader = ClaudeStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: nil,
                          now: t.addingTimeInterval(5), lastEventWasTurnCompletion: false)
    #expect(s == .working)
}

@Test func staleNonCompletedIsIdle() {
    let reader = ClaudeStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: "x",
                          now: t.addingTimeInterval(60), lastEventWasTurnCompletion: false)
    #expect(s == .idle(since: t, lastVerdictSnippet: "x"))
}

@Test func runningWithNoEventIsStartingEvenIfCompletionFlagSet() {
    let reader = ClaudeStatusReader()
    let s = reader.status(processState: .running, lastEventAt: nil, lastVerdictSnippet: nil,
                          now: Date(), lastEventWasTurnCompletion: true)
    #expect(s == .starting)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter completedTurnYieldsAwaitingInputEvenWhenStale`
Expected: FAIL — `awaitingInput` case and the `lastEventWasTurnCompletion:` parameter don't exist (compile error).

- [ ] **Step 3: Add the `.awaitingInput` case**

In `ClaudeStatus.swift`, add the case between `working` and `idle`:

```swift
public enum ClaudeStatus: Sendable, Equatable {
    case starting
    case working
    case awaitingInput(since: Date, lastVerdictSnippet: String?)
    case idle(since: Date, lastVerdictSnippet: String?)
    case ready(exitCode: Int32)
    case failed(reason: String)
}
```

- [ ] **Step 4: Update the reader**

In `ClaudeStatusReader.swift`, change the `status(...)` signature to add the trailing parameter and rewrite the `.running` branch:

```swift
    public func status(
        processState: ClaudeSessionState,
        lastEventAt: Date?,
        lastVerdictSnippet: String?,
        now: Date = Date(),
        lastEventWasTurnCompletion: Bool = false
    ) -> ClaudeStatus {
        switch processState {
        case .failedToLaunch(let reason):
            return .failed(reason: reason)
        case .exited(let code):
            return .ready(exitCode: code)
        case .starting:
            return .starting
        case .running:
            guard let lastEventAt else {
                return .starting
            }
            if lastEventWasTurnCompletion {
                return .awaitingInput(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
            if now.timeIntervalSince(lastEventAt) < idleThresholdSeconds {
                return .working
            } else {
                return .idle(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter ClaudeStatusReaderTests`
Expected: PASS (the four new tests plus any pre-existing ones; the default `lastEventWasTurnCompletion: false` keeps old call sites valid).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/ClaudeSessionKit/ClaudeStatus.swift Core/Sources/ClaudeSessionKit/ClaudeStatusReader.swift Core/Tests/ClaudeSessionKitTests/ClaudeStatusReaderTests.swift
git commit -m "feat(status): add awaiting-input Claude status" --no-verify
```

---

### Task 2: AppModel — awaiting-input wiring + notification re-arm

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `ClaudeStatus.awaitingInput`, the reader's `lastEventWasTurnCompletion:` parameter (Task 1).
- Produces: status becomes `.awaitingInput` on a completed-turn transcript event; notification fires on `working → awaitingInput` and re-arms on return to `.working`.

- [ ] **Step 1: Update the two affected existing tests + add the re-arm test**

In `Core/Tests/AppCoreTests/AppModelTests.swift`:

(a) In `completedTurnStampsReviewed`, the trailing notification assertion must change — completing a turn now yields `.awaitingInput`, which fires the notification. Replace the final block:

```swift
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt != nil)

    // Completing a turn now yields .awaitingInput, which fires the "needs you" notification.
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.reviewID == review.id)
```

(b) Replace the entire `firstIdleTransitionFiresNotificationOnce` test with this awaiting-input version:

```swift
@Test @MainActor func awaitingInputFiresNotificationOnceAndRearms() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    // Working: a non-completing event at t0 (now == t0 → within threshold).
    let t0 = Date()
    model.handleTranscriptEvent(reviewID: review.id, at: t0, snippet: "working", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: t0)

    // Turn completes → awaitingInput → fires once.
    let t1 = t0.addingTimeInterval(1)
    model.handleTranscriptEvent(reviewID: review.id, at: t1, snippet: "done", turnCompleted: true)
    model.recomputeStatus(for: review.id, now: t1)

    // Still awaiting on a later recompute → no second fire.
    model.recomputeStatus(for: review.id, now: t1.addingTimeInterval(1))

    try await Task.sleep(nanoseconds: 150_000_000)
    var posted = await poster.posted
    #expect(posted.count == 1)

    // User replies (working again) re-arms; the next completion fires again.
    let t2 = t1.addingTimeInterval(2)
    model.handleTranscriptEvent(reviewID: review.id, at: t2, snippet: "more", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: t2)
    let t3 = t2.addingTimeInterval(1)
    model.handleTranscriptEvent(reviewID: review.id, at: t3, snippet: "done2", turnCompleted: true)
    model.recomputeStatus(for: review.id, now: t3)

    try await Task.sleep(nanoseconds: 150_000_000)
    posted = await poster.posted
    #expect(posted.count == 2)
}
```

Leave `idleWithoutCompletedTurnDoesNotStampReviewed` unchanged — a stale, non-completing event still yields `.idle` and no reviewed stamp.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path Core --filter awaitingInputFiresNotificationOnceAndRearms`
Expected: FAIL — currently a completed turn yields `.idle`/no awaiting status and the notification gate is idle-based, so the re-arm/second-fire assertion fails (and `completedTurnStampsReviewed` now expects 1 but gets 0).

- [ ] **Step 3: Track the turn-completion flag**

In `AppModel.swift`, add the storage near `private var lastEventAt: [String: Date] = [:]`:

```swift
    private var lastEventWasTurnCompletion: [String: Bool] = [:]
```

In `handleTranscriptEvent`, set it inside the `isNewer` block:

```swift
        if isNewer {
            lastEventAt[reviewID] = date
            lastEventWasTurnCompletion[reviewID] = turnCompleted
        }
```

- [ ] **Step 4: Feed it to the reader and re-arm on working**

In `recomputeStatus`, pass the flag and add the re-arm line. Replace the body up to the fire check:

```swift
    func recomputeStatus(for reviewID: String, now: Date = Date()) {
        let processState = claudeSessions[reviewID]?.state ?? .starting
        let newStatus = statusReader.status(
            processState: processState,
            lastEventAt: lastEventAt[reviewID],
            lastVerdictSnippet: lastVerdictSnippet[reviewID],
            now: now,
            lastEventWasTurnCompletion: lastEventWasTurnCompletion[reviewID] ?? false
        )
        let oldStatus = claudeStatuses[reviewID]
        claudeStatuses[reviewID] = newStatus
        if case .working = newStatus {
            notifiedAwaitingForSession.remove(reviewID)
        }
        if shouldFireReviewReady(old: oldStatus, new: newStatus, reviewID: reviewID) {
            notifiedAwaitingForSession.insert(reviewID)
            postReviewReadyNotification(for: reviewID, status: newStatus)
        }
    }
```

- [ ] **Step 5: Retarget the notification gate to awaiting-input**

Rename the state set `notifiedIdleForSession` → `notifiedAwaitingForSession` at ALL of its sites:
- declaration: `private var notifiedAwaitingForSession: Set<String> = []`
- `recomputeStatus` insert (done in Step 4)
- `terminateClaudeSession`: `notifiedAwaitingForSession.remove(id)`
- `terminateAllClaudeSessions`: `notifiedAwaitingForSession.removeAll()`

Replace `shouldFireReviewReady`:

```swift
    private func shouldFireReviewReady(old: ClaudeStatus?, new: ClaudeStatus, reviewID: String) -> Bool {
        guard !notifiedAwaitingForSession.contains(reviewID) else { return false }
        guard case .awaitingInput = new else { return false }
        return true
    }
```

In `postReviewReadyNotification`, read the snippet from the awaiting case:

```swift
        var snippet: String? = nil
        if case .awaitingInput(_, let s) = status { snippet = s }
```

- [ ] **Step 6: Clean up the new dictionary on teardown**

In `terminateClaudeSession(for id:)` add:

```swift
        lastEventWasTurnCompletion.removeValue(forKey: id)
```

In `terminateAllClaudeSessions()` add:

```swift
        lastEventWasTurnCompletion.removeAll()
```

- [ ] **Step 7: Run the updated tests**

Run: `swift test --package-path Core --filter awaitingInputFiresNotificationOnceAndRearms` then
`swift test --package-path Core --filter completedTurnStampsReviewed` then
`swift test --package-path Core --filter idleWithoutCompletedTurnDoesNotStampReviewed`
Expected: PASS for all three.

- [ ] **Step 8: Run the full AppCore + ClaudeSessionKit suites**

Run: `swift test --package-path Core --filter AppCoreTests` then
`swift test --package-path Core --filter ClaudeSessionKitTests`
Expected: PASS (no regressions; the renamed set and new param are internal).

- [ ] **Step 9: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): drive awaiting-input status and retarget notifications" --no-verify
```

---

### Task 3: `Pushability` ahead/behind counts

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppModel.Pushability` gains `public var ahead: Int` and `public var behind: Int`, populated by `refreshPushability(for:)`.

- [ ] **Step 1: Write the failing test**

Add to `Core/Tests/AppCoreTests/AppModelTests.swift` (uses the existing `StubWorktreeOps` setters and `sampleReview()` whose `headBranch` is `"fix/centrifuge"`):

```swift
@Test @MainActor func refreshPushabilityStoresAheadBehindCounts() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "fix/centrifuge")
    await ops.set(aheadBehindByUpstream: ["origin/fix/centrifuge": (ahead: 3, behind: 2)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureClaudeSession(for: review)   // sets worktreePath via the stub provider
    await model.refreshPushability(for: review.id)

    let p = model.pushability[review.id]
    #expect(p?.ahead == 3)
    #expect(p?.behind == 2)
    #expect(p?.canPush == true)
    #expect(p?.needsForce == true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path Core --filter refreshPushabilityStoresAheadBehindCounts`
Expected: FAIL — `Pushability` has no `ahead`/`behind` members (compile error).

- [ ] **Step 3: Add the fields to `Pushability`**

In `AppModel.swift`, extend the struct:

```swift
    public struct Pushability: Sendable, Equatable {
        public var canPush: Bool
        public var needsForce: Bool
        public var ahead: Int
        public var behind: Int
    }
```

- [ ] **Step 4: Populate the counts in `refreshPushability`**

Replace the two `Pushability(...)` constructions:

```swift
        if let counts = try? await worktreeOps.aheadBehind(worktreePath: worktreePath, upstream: "origin/\(branch)") {
            pushability[id] = Pushability(canPush: counts.ahead > 0, needsForce: counts.behind > 0, ahead: counts.ahead, behind: counts.behind)
        } else if let base = try? await worktreeOps.aheadBehind(worktreePath: worktreePath, upstream: "origin/\(item.baseBranch)") {
            pushability[id] = Pushability(canPush: base.ahead > 0, needsForce: false, ahead: base.ahead, behind: 0)
        } else {
            pushability[id] = nil
        }
```

- [ ] **Step 5: Run the test, then the full AppCore suite**

Run: `swift test --package-path Core --filter refreshPushabilityStoresAheadBehindCounts` then
`swift test --package-path Core --filter AppCoreTests`
Expected: PASS (any pre-existing pushability test still compiles — it only reads `canPush`/`needsForce`, which are unchanged).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): expose ahead/behind counts on Pushability" --no-verify
```

---

### Task 4: `SidebarFilter` + `sidebarItemMatches`

**Files:**
- Create: `Core/Sources/PRPilotModels/SidebarFilter.swift`
- Test: `Core/Tests/PRPilotModelsTests/SidebarFilterTests.swift`

**Interfaces:**
- Produces:
  - `enum SidebarFilter: Sendable, Equatable, CaseIterable { case all, active, awaiting }`
  - `func sidebarItemMatches(_ item: WorkItem, query: String, filter: SidebarFilter, isWorking: Bool, isAwaiting: Bool) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/PRPilotModelsTests/SidebarFilterTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

private func sample() -> WorkItem {
    WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"),
        prState: .open, origin: .added, addedAt: Date()
    )
}

@Test func emptyQueryAllFilterMatches() {
    #expect(sidebarItemMatches(sample(), query: "", filter: .all, isWorking: false, isAwaiting: false))
}

@Test func queryMatchesEachField() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "centrifuge", filter: .all, isWorking: false, isAwaiting: false))   // title
    #expect(sidebarItemMatches(i, query: "teranode", filter: .all, isWorking: false, isAwaiting: false))     // repo
    #expect(sidebarItemMatches(i, query: "icellan", filter: .all, isWorking: false, isAwaiting: false))      // author
    #expect(sidebarItemMatches(i, query: "fix/cent", filter: .all, isWorking: false, isAwaiting: false))     // branch
    #expect(sidebarItemMatches(i, query: "#944", filter: .all, isWorking: false, isAwaiting: false))         // number
    #expect(sidebarItemMatches(i, query: "TERANODE", filter: .all, isWorking: false, isAwaiting: false))     // case-insensitive
}

@Test func nonMatchingQueryFails() {
    #expect(!sidebarItemMatches(sample(), query: "nope-zzz", filter: .all, isWorking: false, isAwaiting: false))
}

@Test func activeFilterNeedsWorkingOrAwaiting() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "", filter: .active, isWorking: true, isAwaiting: false))
    #expect(sidebarItemMatches(i, query: "", filter: .active, isWorking: false, isAwaiting: true))
    #expect(!sidebarItemMatches(i, query: "", filter: .active, isWorking: false, isAwaiting: false))
}

@Test func awaitingFilterNeedsAwaiting() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "", filter: .awaiting, isWorking: false, isAwaiting: true))
    #expect(!sidebarItemMatches(i, query: "", filter: .awaiting, isWorking: true, isAwaiting: false))
}

@Test func filterAndQueryBothApply() {
    let i = sample()
    // Query matches but filter excludes (awaiting required, not awaiting) → false.
    #expect(!sidebarItemMatches(i, query: "centrifuge", filter: .awaiting, isWorking: true, isAwaiting: false))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Core --filter emptyQueryAllFilterMatches`
Expected: FAIL — `SidebarFilter` / `sidebarItemMatches` unresolved.

- [ ] **Step 3: Create `SidebarFilter.swift`**

```swift
import Foundation

public enum SidebarFilter: Sendable, Equatable, CaseIterable {
    case all
    case active
    case awaiting
}

/// Pure sidebar match predicate. The caller supplies the live Claude session
/// booleans, so this stays free of any ClaudeSessionKit dependency.
public func sidebarItemMatches(
    _ item: WorkItem,
    query: String,
    filter: SidebarFilter,
    isWorking: Bool,
    isAwaiting: Bool
) -> Bool {
    let matchesFilter: Bool
    switch filter {
    case .all: matchesFilter = true
    case .active: matchesFilter = isWorking || isAwaiting
    case .awaiting: matchesFilter = isAwaiting
    }
    guard matchesFilter else { return false }

    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return true }
    let numberStr = item.displayNumber.map { "#\($0)" } ?? ""
    let haystacks = [
        item.title,
        "\(item.owner)/\(item.repo)",
        item.author ?? "",
        item.headBranch ?? "",
        numberStr,
    ]
    return haystacks.contains { $0.lowercased().contains(q) }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter SidebarFilterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PRPilotModels/SidebarFilter.swift Core/Tests/PRPilotModelsTests/SidebarFilterTests.swift
git commit -m "feat(models): add sidebar search/filter matcher" --no-verify
```

---

### Task 5: ContentView UI — search/pills header, awaiting dot, ahead/behind chips

**Files:**
- Modify: `App/ContentView.swift`

**Interfaces:**
- Consumes: `sidebarItemMatches`, `SidebarFilter` (Task 4); `ClaudeStatus.awaitingInput` (Task 1); `Pushability.ahead`/`behind` (Task 3); existing `StateBadge`, `StatusDot`, `statusTooltip`, `model.claudeStatuses`, `model.pushability`, `sidebarSections`.

This is SwiftUI (App target) — no unit tests; the gate is a successful build plus a manual check.

- [ ] **Step 1: Add state, filtered-items, and status helpers to `ContentView`**

Add near the existing `@State` declarations (`showingAdd`, `showingNewTask`, …):

```swift
    @State private var searchText = ""
    @State private var sidebarFilter: SidebarFilter = .all
```

Add these computed properties / helpers to `ContentView` (e.g. just above `var body`):

```swift
    private func isWorking(_ id: String) -> Bool { model.claudeStatuses[id] == .working }
    private func isAwaiting(_ id: String) -> Bool {
        if case .awaitingInput = model.claudeStatuses[id] { return true }
        return false
    }
    private var filteredReviews: [WorkItem] {
        model.reviews.filter {
            sidebarItemMatches($0, query: searchText, filter: sidebarFilter,
                               isWorking: isWorking($0.id), isAwaiting: isAwaiting($0.id))
        }
    }
    private var activeCount: Int { model.reviews.filter { isWorking($0.id) || isAwaiting($0.id) }.count }
    private var awaitingCount: Int { model.reviews.filter { isAwaiting($0.id) }.count }
```

- [ ] **Step 2: Add the header view + filter pill builder**

Add to `ContentView`:

```swift
    private var sidebarHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                filterPill(.all, label: "All", count: nil)
                filterPill(.active, label: "Active", count: activeCount)
                filterPill(.awaiting, label: "Awaiting", count: awaitingCount)
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    @ViewBuilder
    private func filterPill(_ f: SidebarFilter, label: String, count: Int?) -> some View {
        Button { sidebarFilter = f } label: {
            HStack(spacing: 4) {
                Text(label)
                if let count { Text("\(count)").opacity(0.7) }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(sidebarFilter == f ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 3: Mount the header and feed the sections from `filteredReviews`**

In `body`, the sidebar column currently is `List(selection: $model.selection) { let sections = sidebarSections(items: model.reviews, …) … }`. Wrap it so the header sits above the List, and source the sections from `filteredReviews`:

```swift
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarHeader
                List(selection: $model.selection) {
                    let sections = sidebarSections(
                        items: filteredReviews,
                        myLogin: model.currentLogin,
                        sort: model.settings.sidebarSort
                    )
                    // … the three existing Section blocks unchanged …
                }
                // … keep all existing List modifiers here:
                // .onDeleteCommand { … }
                // .navigationTitle("Reviews")
                // .frame(minWidth: 260)
                // .toolbar { … }
                // .sheet(isPresented: $showingAdd) { … }
                // .sheet(isPresented: $showingNewTask) { … }
            }
        } detail: {
            // … unchanged …
        }
```

Only the `items:` argument changes (`model.reviews` → `filteredReviews`) and the `VStack { sidebarHeader; List … }` wrap is added. Do not alter the `Section`/`sectionBody`/`SidebarSectionHeader` blocks or any List modifier.

- [ ] **Step 4: Awaiting-input dot color + tooltip**

In `StatusDot.color`, add the awaiting case (steady amber, no pulse — `isWorking` stays `status == .working`, so awaiting does not animate):

```swift
        case .awaitingInput:
            return Color(red: 0.95, green: 0.61, blue: 0.07)
```

In the free function `statusTooltip(_:)`, add a case before `case nil`:

```swift
    case .awaitingInput(let since, let snippet):
        let elapsed = Int(Date().timeIntervalSince(since))
        let mins = max(elapsed / 60, 0)
        let base = mins > 0 ? "Awaiting input \(mins)m" : "Awaiting input"
        if let snippet, !snippet.isEmpty {
            return "\(base) · \(snippet)"
        }
        return base
```

- [ ] **Step 5: Ahead/behind chips**

In `sidebarRow(for:)`, immediately AFTER the existing `if let status = model.prStatuses[review.id] { … }` block, add:

```swift
                if let push = model.pushability[review.id], push.ahead > 0 || push.behind > 0 {
                    HStack(spacing: 4) {
                        if push.ahead > 0 { StateBadge(text: "↑\(push.ahead)", color: .green) }
                        if push.behind > 0 { StateBadge(text: "↓\(push.behind)", color: .orange) }
                    }
                }
```

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Manual smoke check**

Launch the app. Confirm: a search field + All/Active/Awaiting pills appear atop the sidebar; typing filters rows (and sections shrink accordingly); the Active/Awaiting pills show counts and filter when clicked. When a Claude session finishes a turn, its dot turns steady amber (vs pulsing blue while working) and the tooltip reads "Awaiting input". An editable branch with unpushed/behind commits shows ↑N / ↓M chips. PR/task rows are otherwise unchanged.

- [ ] **Step 8: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(sidebar): search/filter pills, awaiting-input dot, ahead/behind chips" --no-verify
```

---

## Final verification

- [ ] **Full Core suite**

Run: `swift test --package-path Core`
Expected: PASS, 0 failures (report exact counts).

- [ ] **App build**

Run: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

---

## Self-Review notes (plan vs spec)

- Spec Part A (awaiting status, reader logic, AppModel wiring, notification re-arm, dot/tooltip) → Tasks 1, 2, 5 (Steps 4).
- Spec Part B (SidebarFilter, sidebarItemMatches, search+pills UI) → Tasks 4, 5 (Steps 1–3).
- Spec Part C (Pushability counts, ahead/behind chips) → Tasks 3, 5 (Step 5).
- Spec Testing → reader truth table (Task 1), awaiting+notify+re-arm and updated existing tests (Task 2), pushability counts (Task 3), sidebarItemMatches table (Task 4), UI via build+manual (Task 5).
- Naming consistency: `awaitingInput`, `lastEventWasTurnCompletion`, `notifiedAwaitingForSession`, `shouldFireReviewReady`, `Pushability.ahead`/`behind`, `SidebarFilter`, `sidebarItemMatches`, `filteredReviews`, `isWorking`/`isAwaiting`, `sidebarHeader`/`filterPill` used consistently across tasks.
- `.idle` retained and still produced by the reader (stale + non-completed) and asserted by the unchanged `idleWithoutCompletedTurnDoesNotStampReviewed` test.
