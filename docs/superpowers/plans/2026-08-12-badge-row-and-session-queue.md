# Badge Row and Session Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put every sidebar chip on one wrapping line below the title, and make `autoLoad` mean "review every PR, N at a time" again by draining a real queue.

**Architecture:** Two pure types in `AppCore` hold the decisions — `FlowRows` for line breaking, `SessionQueue` for what to release and start next. The `App` target wraps `FlowRows` in a `Layout` conformer; `AppModel` calls `SessionQueue` from the existing five-second tick.

**Tech Stack:** Swift 6, macOS 14, SwiftUI (`Layout` protocol), Swift Testing, SwiftPM for `Core/`, XcodeGen for the app target.

**Spec:** `docs/superpowers/specs/2026-08-12-badge-row-and-session-queue-design.md`

## Global Constraints

- Swift tools version 6.0, platform `.macOS(.v14)`. The `Layout` protocol needs macOS 13, so the floor is already met.
- Test framework is Swift Testing. Never add XCTest.
- The `App` target has **no test target**. Every decision must live in `AppCore` so it can be tested; `App` may only contain wiring.
- `FlowRows` must never drop a subview. An over-wide item takes a row alone.
- The queue must terminate. It is keyed on `claudeReviewedAt == nil`, so a reviewed item leaves permanently.
- One queue step per tick. Do not drain in a burst.
- Never write comments unless this plan shows them. The codebase comments the *why*, not the *what*.
- Separate blocks of logic with blank lines.
- Baseline before any change: **462 tests pass, exit code 0**.
- Full test command: `cd Core && swift test`
- App build: `xcodegen generate` once per fresh checkout, then
  `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`

## Existing Code This Depends On

- `StateBadge` at `App/ContentView.swift:560` — the chip view. Unchanged by this plan.
- `sidebarRow(for:)` at `App/ContentView.swift:239` — the row. Restructured in Task 3.
- `SessionBudget.Candidate(id:lastOpenedAt:status:startedAt:)` and
  `SessionBudget.startupGraceSeconds` in `Core/Sources/AppCore/SessionBudget.swift`. Task 4
  reuses both rather than restating the protection rule.
- `tickAllActiveStatuses()` at `AppModel.swift:140`, called every five seconds. Task 5
  hooks the drain here.
- `WorkItem.autoReview` is **dead** — declared and persisted, never read. Do not use it.
  The queue keys off `settings.autoLoad`.

## File Structure

**Create:**

- `Core/Sources/AppCore/FlowRows.swift` — line-breaking arithmetic
- `Core/Sources/AppCore/SessionQueue.swift` — what to release and start next
- `Core/Tests/AppCoreTests/FlowRowsTests.swift`
- `Core/Tests/AppCoreTests/SessionQueueTests.swift`
- `App/WrappingHStack.swift` — the `Layout` conformer

**Modify:**

- `App/ContentView.swift` — one badge line, QUEUED chip
- `Core/Sources/AppCore/AppModel.swift` — queue derivation and drain
- `App/SettingsView.swift` — honest `autoLoad` copy
- `Core/Tests/AppCoreTests/AppModelTests.swift`

---

### Task 1: `FlowRows`

**Files:**
- Create: `Core/Sources/AppCore/FlowRows.swift`
- Test: `Core/Tests/AppCoreTests/FlowRowsTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `FlowRows.rows(widths:spacing:maxWidth:) -> [[Int]]`, subview indices grouped into rows, in order

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/FlowRowsTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import AppCore

@Test func flowRowsPutsEverythingOnOneRowWhenItFits() {
    let rows = FlowRows.rows(widths: [30, 40, 20], spacing: 4, maxWidth: 200)

    #expect(rows == [[0, 1, 2]])
}

@Test func flowRowsWrapsWhenTheNextItemWouldOverflow() {
    let rows = FlowRows.rows(widths: [60, 60, 60], spacing: 4, maxWidth: 130)

    #expect(rows == [[0, 1], [2]])
}

/// Spacing counts between items but not before the first. 60 + 4 + 60 == 124, so a
/// maxWidth of exactly 124 must still fit both.
@Test func flowRowsFitsExactlyAtTheBoundary() {
    let rows = FlowRows.rows(widths: [60, 60], spacing: 4, maxWidth: 124)

    #expect(rows == [[0, 1]])
}

@Test func flowRowsWrapsOnePointPastTheBoundary() {
    let rows = FlowRows.rows(widths: [60, 60], spacing: 4, maxWidth: 123)

    #expect(rows == [[0], [1]])
}

/// Never drop a subview. A hidden failing-CI chip is the thing the user most needs to see.
@Test func flowRowsGivesAnOverWideItemItsOwnRow() {
    let rows = FlowRows.rows(widths: [20, 500, 20], spacing: 4, maxWidth: 100)

    #expect(rows == [[0], [1], [2]])
}

@Test func flowRowsHandlesAnOverWideFirstItem() {
    let rows = FlowRows.rows(widths: [500, 20], spacing: 4, maxWidth: 100)

    #expect(rows == [[0], [1]])
}

@Test func flowRowsReturnsNothingForNoItems() {
    #expect(FlowRows.rows(widths: [], spacing: 4, maxWidth: 100).isEmpty)
}

@Test func flowRowsToleratesAZeroMaxWidth() {
    let rows = FlowRows.rows(widths: [10, 10], spacing: 4, maxWidth: 0)

    #expect(rows == [[0], [1]])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter flowRows`
Expected: compile failure — `cannot find 'FlowRows' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/AppCore/FlowRows.swift`:

```swift
import CoreGraphics

/// Groups subview widths into rows that fit a maximum width. Kept apart from SwiftUI so
/// the arithmetic can be tested, and so a `Layout`'s measurement and placement passes
/// cannot disagree — both call this.
public enum FlowRows {
    /// - Returns: subview indices grouped into rows, in order. Never drops an index; an
    ///   item wider than `maxWidth` occupies a row alone.
    public static func rows(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0

        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > maxWidth {
                rows.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }

        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
```

The `!current.isEmpty` guard is what keeps an over-wide item from being dropped: it is
placed on a fresh row and then overflows that row rather than being skipped.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter flowRows`
Expected: 8 tests pass

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 470 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/FlowRows.swift Core/Tests/AppCoreTests/FlowRowsTests.swift
git commit -m "feat(appcore): add flow-row line breaking"
```

---

### Task 2: `WrappingHStack`

**Files:**
- Create: `App/WrappingHStack.swift`

**Interfaces:**
- Consumes: `FlowRows.rows(widths:spacing:maxWidth:)` from Task 1
- Produces: `WrappingHStack(spacing:lineSpacing:) { … }`, a `Layout`

No automated test — the `App` target has no test target, and Task 1 covers the arithmetic.

- [ ] **Step 1: Write the layout**

Create `App/WrappingHStack.swift`:

```swift
import AppCore
import SwiftUI

/// Lays subviews out left to right, wrapping to a new line rather than clipping. Both
/// passes call `FlowRows`, so measurement and placement cannot disagree.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return .zero }

        let maxWidth = proposal.width ?? .infinity
        let rows = FlowRows.rows(widths: sizes.map(\.width), spacing: spacing, maxWidth: maxWidth)

        let width = rows
            .map { row in
                row.reduce(CGFloat(0)) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, row.count - 1))
            }
            .max() ?? 0
        let height = rows
            .map { row in row.map { sizes[$0].height }.max() ?? 0 }
            .reduce(CGFloat(0), +) + lineSpacing * CGFloat(max(0, rows.count - 1))

        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return }

        let rows = FlowRows.rows(widths: sizes.map(\.width), spacing: spacing, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - sizes[index].height) / 2),
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

XcodeGen picks up new files under `App/` automatically. If the build cannot find
`WrappingHStack`, run `xcodegen generate` and build again.

- [ ] **Step 3: Commit**

```bash
git add App/WrappingHStack.swift
git commit -m "feat(app): add a wrapping horizontal layout"
```

---

### Task 3: One badge line per row

**Files:**
- Modify: `App/ContentView.swift:239-282` and `:376-401`

**Interfaces:**
- Consumes: `WrappingHStack` from Task 2
- Produces: `badgeLine(for:)`, replacing `statusBadge(for:)`

**Why the title changes.** `Text` at line 244 carries `.lineLimit(1)` and shares an
`HStack(spacing: 4)` with the badges, with no `Spacer`. Every chip therefore steals width
from the title. Removing the badges from that row is the fix.

No automated test. Step 4 is a visual check.

- [ ] **Step 1: Replace the title row and add the badge line**

In `App/ContentView.swift`, replace the first two children of the row's `VStack`:

```swift
                HStack(spacing: 4) {
                    Text(review.number.map { "#\($0) · \(review.title)" } ?? review.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    statusBadge(for: review)
                }
```

with:

```swift
                Text(review.number.map { "#\($0) · \(review.title)" } ?? review.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                badgeLine(for: review)
```

- [ ] **Step 2: Delete the two old chip rows**

Still inside the same `VStack`, delete these two blocks entirely. Their contents move into
`badgeLine` in Step 3:

```swift
                if let status = model.prStatuses[review.id] {
                    HStack(spacing: 4) {
                        switch status.ci {
                        case .passing: StateBadge(text: "✓ CI", color: .green)
                        case .failing: StateBadge(text: "✗ CI", color: .red)
                        case .pending: StateBadge(text: "◷ CI", color: .orange)
                        case .none: EmptyView()
                        }
                        if status.isBehind { StateBadge(text: "behind", color: .orange) }
                        if status.readiness == .changesRequested { StateBadge(text: "changes", color: .red) }
                        if model.hasUnseenAuthorUpdate(review) { StateBadge(text: "Updated", color: .teal) }
                    }
                }
                if let push = model.pushability[review.id], push.ahead > 0 || push.behind > 0 {
                    HStack(spacing: 4) {
                        if push.ahead > 0 { StateBadge(text: "↑\(push.ahead)", color: .green) }
                        if push.behind > 0 { StateBadge(text: "↓\(push.behind)", color: .orange) }
                    }
                }
```

- [ ] **Step 3: Replace `statusBadge(for:)` with `badgeLine(for:)`**

Replace the whole of `statusBadge(for:)` at line 376:

```swift
    @ViewBuilder
    private func badgeLine(for review: WorkItem) -> some View {
        WrappingHStack(spacing: 4, lineSpacing: 4) {
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

            if let status = model.prStatuses[review.id] {
                switch status.ci {
                case .passing: StateBadge(text: "✓ CI", color: .green)
                case .failing: StateBadge(text: "✗ CI", color: .red)
                case .pending: StateBadge(text: "◷ CI", color: .orange)
                case .none: EmptyView()
                }
                if status.isBehind { StateBadge(text: "behind", color: .orange) }
                if status.readiness == .changesRequested { StateBadge(text: "changes", color: .red) }
                if model.hasUnseenAuthorUpdate(review) { StateBadge(text: "Updated", color: .teal) }
            }

            if let push = model.pushability[review.id] {
                if push.ahead > 0 { StateBadge(text: "↑\(push.ahead)", color: .green) }
                if push.behind > 0 { StateBadge(text: "↓\(push.behind)", color: .orange) }
            }
        }
    }
```

The QUEUED chip is added in Task 6, once the queue exists.

- [ ] **Step 4: Build and check by eye**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Launch the app and confirm:

- Chips sit on their own line below the title, not beside it.
- A long title now uses the full sidebar width.
- A row with CI and push chips is no taller than before, and usually shorter.
- Narrowing the sidebar wraps the chips instead of clipping them.
- Issues still show their single issue badge.

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(sidebar): put every chip on one wrapping line below the title"
```

---

### Task 4: `SessionQueue`

**Files:**
- Create: `Core/Sources/AppCore/SessionQueue.swift`
- Test: `Core/Tests/AppCoreTests/SessionQueueTests.swift`

**Interfaces:**
- Consumes: `SessionBudget.Candidate(id:lastOpenedAt:status:startedAt:)` and `SessionBudget.startupGraceSeconds`
- Produces: `SessionQueue.Step(release:start:)` and `SessionQueue.nextStep(queued:live:cap:selectedID:now:) -> Step`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/SessionQueueTests.swift`:

```swift
import Testing
import Foundation
import ClaudeSessionKit
@testable import AppCore

private let queueNow = Date(timeIntervalSince1970: 1_000_000)

private func live(
    _ id: String,
    minutesAgo: Int,
    status: ClaudeStatus = .idle(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil),
    startedSecondsAgo: TimeInterval = 3600
) -> SessionBudget.Candidate {
    SessionBudget.Candidate(
        id: id,
        lastOpenedAt: queueNow.addingTimeInterval(-Double(minutesAgo) * 60),
        status: status,
        startedAt: queueNow.addingTimeInterval(-startedSecondsAgo)
    )
}

private func step(
    queued: [String],
    live sessions: [SessionBudget.Candidate],
    cap: Int,
    selectedID: String? = nil
) -> SessionQueue.Step {
    SessionQueue.nextStep(
        queued: queued,
        live: sessions,
        cap: cap,
        selectedID: selectedID,
        now: queueNow
    )
}

@Test func queueDoesNothingWhenNothingIsQueued() {
    let result = step(queued: [], live: [live("a", minutesAgo: 1)], cap: 1)

    #expect(result.release == nil)
    #expect(result.start == nil)
}

@Test func queueStartsTheHeadWhenASlotIsFree() {
    let result = step(queued: ["next"], live: [live("a", minutesAgo: 1)], cap: 3)

    #expect(result.release == nil)
    #expect(result.start == "next")
}

@Test func queueReleasesTheOldestIdleSessionAtTheCap() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5)],
        cap: 2
    )

    #expect(result.release == "oldest")
    #expect(result.start == "next")
}

@Test func queueNeverReleasesAWorkingSession() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5, status: .working)],
        cap: 2
    )

    #expect(result.release == "newest")
    #expect(result.start == "next")
}

@Test func queueNeverReleasesASessionInsideItsStartupGrace() {
    let result = step(
        queued: ["next"],
        live: [
            live("newest", minutesAgo: 1),
            live("starting", minutesAgo: 5, status: .starting, startedSecondsAgo: 10),
        ],
        cap: 2
    )

    #expect(result.release == "newest")
}

@Test func queueNeverReleasesTheSelectedItem() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5)],
        cap: 2,
        selectedID: "oldest"
    )

    #expect(result.release == "newest")
    #expect(result.start == "next")
}

@Test func queueDoesNothingWhenEverySessionIsProtected() {
    let result = step(
        queued: ["next"],
        live: [
            live("a", minutesAgo: 1, status: .working),
            live("b", minutesAgo: 5, status: .working),
        ],
        cap: 2
    )

    #expect(result.release == nil)
    #expect(result.start == nil)
}

@Test func queueReleasesAFinishedSessionSoTheBacklogMoves() {
    let result = step(
        queued: ["next"],
        live: [live("done", minutesAgo: 5, status: .ready(exitCode: 0))],
        cap: 1
    )

    #expect(result.release == "done")
    #expect(result.start == "next")
}

@Test func queueReleasesAnAwaitingInputSessionEvenThoughItIsUnread() {
    let unread = ClaudeStatus.awaitingInput(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: "verdict")
    let result = step(
        queued: ["next"],
        live: [live("unread", minutesAgo: 5, status: unread)],
        cap: 1
    )

    #expect(result.release == "unread")
}

@Test func queueDoesNothingForANonPositiveCap() {
    let result = step(queued: ["next"], live: [], cap: 0)

    #expect(result.release == nil)
    #expect(result.start == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter queue`
Expected: compile failure — `cannot find 'SessionQueue' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/AppCore/SessionQueue.swift`:

```swift
import Foundation
import ClaudeSessionKit

/// Decides one step of draining the review backlog: which finished session gives up its
/// slot, and which queued item takes it.
///
/// A finished review releases its process before the user has read it. Nothing is lost —
/// the transcript survives and `ensureClaudeSession` resumes it — and holding the slot
/// would stall the backlog behind whatever the user has not got round to reading.
public enum SessionQueue {
    public struct Step: Sendable, Equatable {
        public let release: String?
        public let start: String?

        public init(release: String?, start: String?) {
            self.release = release
            self.start = start
        }
    }

    public static func nextStep(
        queued: [String],
        live: [SessionBudget.Candidate],
        cap: Int,
        selectedID: String?,
        now: Date
    ) -> Step {
        guard cap > 0, let next = queued.first else { return Step(release: nil, start: nil) }
        guard live.count >= cap else { return Step(release: nil, start: next) }

        let releasable = live
            .filter { $0.id != selectedID }
            .filter { !isProtected($0, now: now) }
            .min { left, right in
                if left.lastOpenedAt == right.lastOpenedAt { return left.id < right.id }
                return left.lastOpenedAt < right.lastOpenedAt
            }

        guard let releasable else { return Step(release: nil, start: nil) }
        return Step(release: releasable.id, start: next)
    }

    /// Same rule as `SessionBudget`: a session mid-turn keeps its slot, and a launching one
    /// gets a grace period before it counts as idle.
    private static func isProtected(_ candidate: SessionBudget.Candidate, now: Date) -> Bool {
        switch candidate.status {
        case .working:
            return true
        case .starting:
            return now.timeIntervalSince(candidate.startedAt) <= SessionBudget.startupGraceSeconds
        case .awaitingInput, .idle, .ready, .failed:
            return false
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter queue`
Expected: 10 tests pass

- [ ] **Step 5: Run the full suite**

Run: `cd Core && swift test`
Expected: 480 tests pass, exit code 0

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/SessionQueue.swift Core/Tests/AppCoreTests/SessionQueueTests.swift
git commit -m "feat(appcore): decide the next session queue step"
```

---

### Task 5: Derive the queue and drain it

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift:140`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `SessionQueue.nextStep(queued:live:cap:selectedID:now:)` from Task 4
- Produces: `AppModel.queuedReviewIDs: [String]` (public, observable) and `AppModel.drainSessionQueue() async`

**Why keyed on `claudeReviewedAt`.** It is stamped on the first completed turn and never
cleared except by `clearClaudeSession`. That is what makes the queue finite: each finished
review leaves it permanently. Keying on anything that resets would loop for ever.

- [ ] **Step 1: Write the failing tests**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift`. Reuse `tempStoreURL()`,
`cappedReview(_:number:openedMinutesAgo:)`, `cappedModel(store:)` and
`registerExistingClone(in:)`:

```swift
@Test @MainActor func queueIsEmptyWhenAutoLoadIsOff() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(cappedReview("q1", number: 1, openedMinutesAgo: 1))
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs.isEmpty)
}

@Test @MainActor func queueHoldsNeverReviewedItemsMostRecentFirst() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("q\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs == ["item-q1", "item-q2", "item-q3"])
}

@Test @MainActor func queueExcludesReviewedDisabledAndCloneLessItems() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var reviewed = cappedReview("done", number: 1, openedMinutesAgo: 1)
    reviewed.claudeReviewedAt = Date(timeIntervalSince1970: 500)
    var disabled = cappedReview("off", number: 2, openedMinutesAgo: 2)
    disabled.disabled = true
    let plain = cappedReview("keep", number: 3, openedMinutesAgo: 3)
    var otherRepo = cappedReview("noclone", number: 4, openedMinutesAgo: 4)
    otherRepo.repoKey = "github.com/other/repo"
    for item in [reviewed, disabled, plain, otherRepo] { try await store.upsertItem(item) }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs == ["item-keep"])
}

@Test @MainActor func drainStartsAQueuedSessionWhenASlotIsFree() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("d\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.drainSessionQueue()

    #expect(model.claudeSessions.count == 1)
    #expect(model.claudeSessions["item-d1"] != nil)
}

/// One step per tick, so the backlog moves steadily rather than in a burst.
@Test @MainActor func drainStartsOneSessionPerCall() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("d\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 3
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.drainSessionQueue()
    await model.drainSessionQueue()

    #expect(model.claudeSessions.count == 2)
}

@Test @MainActor func drainReleasesAnIdleSessionAtTheCapAndStartsTheNext() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...2 {
        try await store.upsertItem(cappedReview("r\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    await model.drainSessionQueue()
    let firstStarted = model.claudeSessions["item-r1"] != nil

    // ClaudeSession.start runs `cd <cwd> && exec <claude>`, and StubWorktreeProvider's
    // /tmp/wt does not exist, so the shell exits and the status settles to .ready —
    // releasable. The wait covers `zsh -l` sourcing a slow profile before it can fail.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    model.recomputeStatus(for: "item-r1", now: Date())
    #expect(model.claudeStatuses["item-r1"] != .working)

    await model.drainSessionQueue()

    #expect(firstStarted == true)
    #expect(model.claudeSessions["item-r1"] == nil)
    #expect(model.claudeSessions["item-r2"] != nil)
    #expect(model.claudeSessions.count == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter "queueIsEmpty|queueHolds|queueExcludes|drainStarts|drainReleases"`
Expected: compile failure — `value of type 'AppModel' has no member 'queuedReviewIDs'`

- [ ] **Step 3: Add the derivation**

In `Core/Sources/AppCore/AppModel.swift`, add beside the other observable properties near
line 35:

```swift
    /// Items autoLoad wants reviewed that have no session yet, most recently opened first.
    public private(set) var queuedReviewIDs: [String] = []
```

Add the recompute and the drain, beside `enforceSessionBudget`:

```swift
    /// Keyed on `claudeReviewedAt` being nil, which is what makes the queue finite: the
    /// stamp survives a session ending, so a reviewed item leaves the queue for good.
    func recomputeReviewQueue() {
        guard settings.autoLoad else {
            queuedReviewIDs = []
            return
        }
        queuedReviewIDs = reviews
            .filter { !$0.disabled }
            .filter { $0.claudeReviewedAt == nil }
            .filter { claudeSessions[$0.id] == nil }
            .filter { review in
                guard let clonePath = registeredClonePath(for: review) else { return false }
                return FileManager.default.fileExists(atPath: clonePath)
            }
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
            .map(\.id)
    }

    /// One step per call. Starting a session does real work, so pacing it keeps the launch
    /// path calm and lets a released slot settle before the next start.
    func drainSessionQueue(now: Date = Date()) async {
        recomputeReviewQueue()
        let candidates: [SessionBudget.Candidate] = claudeSessions.keys.compactMap { id in
            guard let review = reviews.first(where: { $0.id == id }) else { return nil }
            return SessionBudget.Candidate(
                id: id,
                lastOpenedAt: review.lastOpenedAt ?? review.addedAt,
                status: claudeStatuses[id] ?? .starting,
                startedAt: sessionStartedAt[id] ?? now
            )
        }
        let step = SessionQueue.nextStep(
            queued: queuedReviewIDs,
            live: candidates,
            cap: settings.maxLiveClaudeSessions,
            selectedID: selection,
            now: now
        )
        if let release = step.release {
            evictClaudeSession(for: release)
        }
        guard let start = step.start,
              let review = reviews.first(where: { $0.id == start }) else { return }
        await ensureClaudeSession(for: review)
        recomputeReviewQueue()
    }
```

`evictClaudeSession` is private. Keep `drainSessionQueue` inside the same type so it can
call it.

- [ ] **Step 4: Hook the drain to the tick**

`tickAllActiveStatuses()` at line 140 is unchanged. Only its caller changes, so the drain
runs on the same five-second beat. The tick task at line 130 becomes:

```swift
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickIntervalNanoseconds)
                self.tickAllActiveStatuses()
                await self.drainSessionQueue()
            }
```

Statuses are recomputed first, so the drain sees a session that has just finished.

Also call `recomputeReviewQueue()` at the end of `load()`, after `startTickTimerIfNeeded()`,
so the chip is right before the first tick.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter "queueIsEmpty|queueHolds|queueExcludes|drainStarts|drainReleases"`
Expected: 6 tests pass

- [ ] **Step 6: Run the full suite**

Run: `cd Core && swift test`
Expected: 486 tests pass, exit code 0

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): drain a review queue so autoLoad reaches every PR again"
```

---

### Task 6: The QUEUED chip and honest Settings copy

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.queuedReviewIDs` from Task 5
- Produces: nothing

No automated test. Task 5 covers the queue; this is wiring and copy.

- [ ] **Step 1: Add the chip**

In `badgeLine(for:)` in `App/ContentView.swift`, inside the non-issue branch, after the
Waiting chip:

```swift
                if model.queuedReviewIDs.contains(review.id) {
                    StateBadge(text: "Queued", color: .gray)
                }
```

Gray is quieter than Waiting's yellow, because a queued item asks nothing of the user.

- [ ] **Step 2: Correct the autoLoad description**

In `App/SettingsView.swift`, replace the caption under the auto-load toggle:

```swift
                Text("Reviews each PR at least once: resumes its session, or starts a fresh review for a new one. Runs at launch and when a PR is added (manually or via discovery). Repos without a local clone are reviewed when first opened.")
```

with:

```swift
                Text("Reviews every PR at least once, up to the live session limit at a time. Items above the limit wait their turn and show a Queued badge; a finished review releases its slot to the next in line. Repos without a local clone are reviewed when first opened.")
```

The old wording promised every PR at once, which the session cap made untrue.

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Check by eye**

Launch the app with `autoLoad` on and a session limit of 2, so the queue is visible.
Confirm:

- Items beyond the limit show a gray **Queued** chip.
- The chip disappears from an item once its session starts.
- Over a few minutes the queue shrinks as reviews complete, without you clicking anything.
- Settings shows the new description.

Turn `autoLoad` back to whatever you had it on before finishing.

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift App/SettingsView.swift
git commit -m "feat(sidebar): show a Queued chip and describe autoLoad accurately"
```

---

## Final Verification

Do not report this work complete without the output of every command below.

- [ ] **Full test suite**

```bash
cd Core && swift test
```

Expected: 486 tests pass, exit code 0. The baseline was 462. Paste the final summary line.

- [ ] **Release build**

```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Watch the queue actually drain**

Set `autoLoad` on and the session limit to 2. Launch the app and leave it alone for five
minutes. Then run:

```bash
app=$(pgrep -f "PRPilot.app/Contents/MacOS/PR Pilot" | head -1)
ps -axo pid,ppid,command | awk -v a="$app" '$2==a' | grep -c claude
```

Expected: the count sits at or below 2 throughout, never climbing. Confirm in the sidebar
that the number of Queued chips has fallen. Report the real numbers, including any case
where the count exceeded the limit.

- [ ] **Confirm no chip is ever hidden**

Narrow the sidebar to its minimum with a row that has many chips. Confirm they wrap onto a
second line and none is clipped.

## Notes For The Implementer

- Test counts assume the 462 baseline. If `swift test` reports something else, report the
  real number and carry the delta through.
- Task 3 deletes two blocks and moves their contents. Delete them rather than leaving them
  in place — duplicated chips are the likely mistake here.
- `WorkItem.autoReview` is dead. Do not be tempted to use it for the queue.
- The drain calls `ensureClaudeSession`, which itself calls `enforceSessionBudget()`. That
  is harmless: the budget only evicts above the cap, and the drain releases before starting
  so the count never exceeds it.
