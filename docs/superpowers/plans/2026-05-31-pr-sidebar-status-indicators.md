# PR Sidebar Status Indicators + Copy Session ID — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each PR's lifecycle status (New / Reviewed / Approved / Merged / Closed / Draft) as an uppercase colored tag in the left sidebar, pulse the live Claude dot while working, and add a right-click "Copy Session ID" action.

**Architecture:** A derived `SidebarStatus` is computed from `Review` fields (no stored status). Two new persisted `Review` fields back the parts that aren't already known: `claudeReviewedAt` (stamped when Claude's review-ready notification fires) and `approvedByMe` (set by polling GitHub). `GitHubClient` gains a current-login lookup and a per-PR review-state fetch; `AppModel` caches the login at launch and refreshes review state on the existing discovery poll (skipping terminal PRs) and on PR open. The sidebar row maps `SidebarStatus` to an uppercase capsule using adaptive SwiftUI system colors, and the `StatusDot` pulses when `.working`.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager (`Core/`), Swift Testing framework (`import Testing`), `gh` CLI via `CommandRunner`.

---

## File Structure

- `Core/Sources/PRReviewModels/Review.swift` — **modify**: add `claudeReviewedAt`, `approvedByMe` (stored + Codable).
- `Core/Sources/PRReviewModels/SidebarStatus.swift` — **create**: `SidebarStatus` enum + `Review.sidebarStatus` computed property.
- `Core/Sources/GitHubKit/GitHubClient.swift` — **modify**: add `fetchCurrentLogin()`, `ReviewState`, `fetchReviewState(for:login:)`, and the `GHReviewStatePayload` decodable.
- `Core/Sources/AppCore/AppModel.swift` — **modify**: cache `currentLogin`, stamp `claudeReviewedAt`, add `refreshReviewState(for:)` / `refreshReviewStates()`, wire into poll + open.
- `App/ContentView.swift` — **modify**: render `statusBadge(for:)`, uppercase `StateBadge`, pulsing `StatusDot`, "Copy Session ID" menu item; add `import AppKit`.
- Tests: `Core/Tests/PRReviewModelsTests/`, `Core/Tests/GitHubKitTests/GitHubClientTests.swift`, `Core/Tests/AppCoreTests/AppModelTests.swift`.

**Test command:** `swift test --package-path Core` (filtered: `swift test --package-path Core --filter <name>`)
**App build:** `xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug build`

---

### Task 1: Add `claudeReviewedAt` and `approvedByMe` to `Review`

**Files:**
- Modify: `Core/Sources/PRReviewModels/Review.swift`
- Test: `Core/Tests/PRReviewModelsTests/ModelsTests.swift`

- [ ] **Step 1: Write failing tests for the new fields + backward compatibility**

Add to `Core/Tests/PRReviewModelsTests/ModelsTests.swift`:

```swift
@Test func reviewEncodesAndDecodesNewStatusFields() throws {
    let review = Review(
        owner: "bsv-blockchain", repo: "teranode", number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "centrifuge fix", author: "icellan",
        headBranch: "fix/centrifuge", baseBranch: "main",
        origin: .added, prState: .open,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        claudeReviewedAt: Date(timeIntervalSince1970: 1_700_000_500),
        approvedByMe: true
    )
    let data = try JSONEncoder().encode(review)
    let decoded = try JSONDecoder().decode(Review.self, from: data)
    #expect(decoded.claudeReviewedAt == Date(timeIntervalSince1970: 1_700_000_500))
    #expect(decoded.approvedByMe == true)
}

@Test func reviewDecodesLegacyJSONWithoutNewFields() throws {
    let legacy = """
    {
      "id": "bsv-blockchain/teranode#944",
      "owner": "bsv-blockchain", "repo": "teranode", "number": 944,
      "url": "https://github.com/bsv-blockchain/teranode/pull/944",
      "title": "centrifuge fix", "author": "icellan",
      "headBranch": "fix/centrifuge", "baseBranch": "main",
      "origin": "added", "prState": "open",
      "addedAt": 631152000, "disabled": false, "viewedFiles": []
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(legacy.utf8))
    #expect(decoded.claudeReviewedAt == nil)
    #expect(decoded.approvedByMe == false)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter reviewEncodesAndDecodesNewStatusFields`
Expected: FAIL — `Review` has no `claudeReviewedAt`/`approvedByMe` argument.

- [ ] **Step 3: Add the stored properties**

In `Core/Sources/PRReviewModels/Review.swift`, after the `viewedFiles` property (line 23), add:

```swift
    public var claudeReviewedAt: Date?
    public var approvedByMe: Bool
```

- [ ] **Step 4: Add the init parameters and assignments**

In the memberwise `init` parameter list, after `viewedFiles: [String] = []` (line 44), add:

```swift
        claudeReviewedAt: Date? = nil,
        approvedByMe: Bool = false,
```

In the `init` body, after `self.viewedFiles = viewedFiles` (line 65), add:

```swift
        self.claudeReviewedAt = claudeReviewedAt
        self.approvedByMe = approvedByMe
```

- [ ] **Step 5: Decode the new fields with backward-compatible defaults**

In `init(from decoder:)`, after `self.viewedFiles = try container.decodeIfPresent([String].self, forKey: .viewedFiles) ?? []` (line 89), add:

```swift
        self.claudeReviewedAt = try container.decodeIfPresent(Date.self, forKey: .claudeReviewedAt)
        self.approvedByMe = try container.decodeIfPresent(Bool.self, forKey: .approvedByMe) ?? false
```

(`CodingKeys` is compiler-synthesized and automatically includes the two new stored properties; `encode(to:)` is synthesized too, so no encode changes are needed.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter "reviewEncodesAndDecodesNewStatusFields|reviewDecodesLegacyJSONWithoutNewFields"`
Expected: PASS (both).

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PRReviewModels/Review.swift Core/Tests/PRReviewModelsTests/ModelsTests.swift
git commit -m "feat: add claudeReviewedAt and approvedByMe to Review model" --no-verify
```

---

### Task 2: `SidebarStatus` enum + `Review.sidebarStatus`

**Files:**
- Create: `Core/Sources/PRReviewModels/SidebarStatus.swift`
- Test: `Core/Tests/PRReviewModelsTests/SidebarStatusTests.swift`

- [ ] **Step 1: Write failing precedence tests**

Create `Core/Tests/PRReviewModelsTests/SidebarStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import PRReviewModels

private func review(
    prState: PRState = .open,
    lastOpenedAt: Date? = nil,
    claudeReviewedAt: Date? = nil,
    approvedByMe: Bool = false
) -> Review {
    Review(
        owner: "o", repo: "r", number: 1,
        url: URL(string: "https://github.com/o/r/pull/1")!,
        title: "t", author: "a", headBranch: "h", baseBranch: "main",
        origin: .added, prState: prState,
        addedAt: Date(timeIntervalSince1970: 0),
        lastOpenedAt: lastOpenedAt,
        claudeReviewedAt: claudeReviewedAt,
        approvedByMe: approvedByMe
    )
}

private let opened = Date(timeIntervalSince1970: 100)
private let claudeDone = Date(timeIntervalSince1970: 200)

@Test func mergedBeatsEverything() {
    #expect(review(prState: .merged, approvedByMe: true).sidebarStatus == .merged)
}

@Test func closedBeatsApproved() {
    #expect(review(prState: .closed, approvedByMe: true).sidebarStatus == .closed)
}

@Test func approvedBeatsNew() {
    #expect(review(lastOpenedAt: nil, approvedByMe: true).sidebarStatus == .approved)
}

@Test func unopenedIsNewEvenWhenClaudeReviewed() {
    #expect(review(lastOpenedAt: nil, claudeReviewedAt: claudeDone).sidebarStatus == .new)
}

@Test func openedAndClaudeReviewedIsReviewed() {
    #expect(review(lastOpenedAt: opened, claudeReviewedAt: claudeDone).sidebarStatus == .reviewed)
}

@Test func openedDraftWithoutReviewIsDraft() {
    #expect(review(prState: .draft, lastOpenedAt: opened).sidebarStatus == .draft)
}

@Test func unopenedDraftIsNew() {
    #expect(review(prState: .draft, lastOpenedAt: nil).sidebarStatus == .new)
}

@Test func openedNothingElseIsOpen() {
    #expect(review(lastOpenedAt: opened).sidebarStatus == .open)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core --filter mergedBeatsEverything`
Expected: FAIL — `sidebarStatus` / `SidebarStatus` not defined.

- [ ] **Step 3: Implement the enum and computed property**

Create `Core/Sources/PRReviewModels/SidebarStatus.swift`:

```swift
import Foundation

public enum SidebarStatus: String, Sendable, Equatable {
    case merged
    case closed
    case approved
    case new
    case reviewed
    case draft
    case open
}

extension Review {
    /// Single lifecycle tag for the sidebar, chosen by precedence:
    /// merged > closed > approved > new > reviewed > draft > open.
    public var sidebarStatus: SidebarStatus {
        switch prState {
        case .merged: return .merged
        case .closed: return .closed
        case .open, .draft: break
        }
        if approvedByMe { return .approved }
        if lastOpenedAt == nil { return .new }
        if claudeReviewedAt != nil { return .reviewed }
        if prState == .draft { return .draft }
        return .open
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core --filter SidebarStatusTests`
Expected: PASS (all 8).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PRReviewModels/SidebarStatus.swift Core/Tests/PRReviewModelsTests/SidebarStatusTests.swift
git commit -m "feat: derive SidebarStatus lifecycle tag from Review" --no-verify
```

---

### Task 3: `GitHubClient` — current login + review-state fetch

**Files:**
- Modify: `Core/Sources/GitHubKit/GitHubClient.swift`
- Test: `Core/Tests/GitHubKitTests/GitHubClientTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Core/Tests/GitHubKitTests/GitHubClientTests.swift` (the file already defines `RecordingRunner` and `QueuedRunner`):

```swift
@Test func fetchCurrentLoginTrimsOutput() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")
    let login = try await client.fetchCurrentLogin()
    #expect(login == "ordishs")
    let args = await runner.lastArguments
    #expect(args == ["api", "user", "--jq", ".login"])
}

@Test func fetchReviewStateApprovedWhenMyLatestDecisiveReviewIsApproved() async throws {
    let json = """
    {"state":"OPEN","isDraft":false,"reviews":[
      {"author":{"login":"someoneelse"},"state":"CHANGES_REQUESTED"},
      {"author":{"login":"ordishs"},"state":"COMMENTED"},
      {"author":{"login":"ordishs"},"state":"APPROVED"},
      {"author":{"login":"ordishs"},"state":"COMMENTED"}
    ]}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let state = try await client.fetchReviewState(for: ref, login: "ordishs")
    #expect(state.approvedByMe == true)
    #expect(state.prState == .open)
}

@Test func fetchReviewStateNotApprovedWhenMyApprovalWasDismissed() async throws {
    let json = """
    {"state":"OPEN","isDraft":false,"reviews":[
      {"author":{"login":"ordishs"},"state":"APPROVED"},
      {"author":{"login":"ordishs"},"state":"DISMISSED"}
    ]}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let state = try await client.fetchReviewState(for: ref, login: "ordishs")
    #expect(state.approvedByMe == false)
}

@Test func fetchReviewStateNotApprovedWhenOnlySomeoneElseApproved() async throws {
    let json = """
    {"state":"MERGED","isDraft":false,"reviews":[
      {"author":{"login":"someoneelse"},"state":"APPROVED"}
    ]}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let state = try await client.fetchReviewState(for: ref, login: "ordishs")
    #expect(state.approvedByMe == false)
    #expect(state.prState == .merged)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core --filter fetchCurrentLoginTrimsOutput`
Expected: FAIL — `fetchCurrentLogin` / `fetchReviewState` not defined.

- [ ] **Step 3: Implement the public API**

In `Core/Sources/GitHubKit/GitHubClient.swift`, add these methods inside the `GitHubClient` type (e.g. after `fetchReview`, before the closing brace of the type around line 55–56):

```swift
    public struct ReviewState: Sendable, Equatable {
        public let approvedByMe: Bool
        public let prState: PRState
        public init(approvedByMe: Bool, prState: PRState) {
            self.approvedByMe = approvedByMe
            self.prState = prState
        }
    }

    public func fetchCurrentLogin() async throws -> String {
        let result = try await runner.run(executable: ghPath, arguments: ["api", "user", "--jq", ".login"])
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let login = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            throw GitHubError.decodingFailed("empty login from gh api user")
        }
        return login
    }

    public func fetchReviewState(for ref: PRRef, login: String) async throws -> ReviewState {
        let result = try await runner.run(
            executable: ghPath,
            arguments: prViewArguments(ref: ref, fields: "state,isDraft,reviews")
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let payload: GHReviewStatePayload
        do {
            payload = try JSONDecoder().decode(GHReviewStatePayload.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let decisive = payload.reviews
            .filter { $0.author?.login == login }
            .filter { ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state) }
        let approvedByMe = decisive.last?.state == "APPROVED"
        return ReviewState(
            approvedByMe: approvedByMe,
            prState: GitHubClient.mapState(state: payload.state, isDraft: payload.isDraft)
        )
    }
```

- [ ] **Step 4: Add the decodable payload**

At the bottom of `Core/Sources/GitHubKit/GitHubClient.swift` (alongside `GHPullRequest`), add:

```swift
struct GHReviewStatePayload: Decodable {
    struct Review: Decodable {
        struct Author: Decodable { let login: String }
        let author: Author?
        let state: String
    }
    let state: String
    let isDraft: Bool
    let reviews: [Review]
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Core --filter "fetchCurrentLoginTrimsOutput|fetchReviewState"`
Expected: PASS (all 4).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/GitHubKit/GitHubClient.swift Core/Tests/GitHubKitTests/GitHubClientTests.swift
git commit -m "feat: fetch current login and PR review state via gh" --no-verify
```

---

### Task 4: `AppModel` — cache login, stamp reviewed, refresh approval (skip terminal)

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
@Test @MainActor func loadCachesCurrentLogin() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.currentLogin == "ordishs")
}

@Test @MainActor func markClaudeReviewedStampsOnce() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsert(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.markClaudeReviewed("bsv-blockchain/teranode#944")
    let first = model.reviews.first?.claudeReviewedAt
    #expect(first != nil)

    await model.markClaudeReviewed("bsv-blockchain/teranode#944")
    #expect(model.reviews.first?.claudeReviewedAt == first)
}

@Test @MainActor func refreshReviewStateSetsApprovedByMe() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsert(sampleReview())
    let reviewsJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[{"author":{"login":"ordishs"},"state":"APPROVED"}]}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: reviewsJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: "bsv-blockchain/teranode#944")

    #expect(model.reviews.first?.approvedByMe == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core --filter loadCachesCurrentLogin`
Expected: FAIL — `currentLogin` / `markClaudeReviewed` / `refreshReviewState` not defined.

- [ ] **Step 3: Add the `currentLogin` property**

In `Core/Sources/AppCore/AppModel.swift`, after the `claudeStatuses` declaration (line 28), add:

```swift
    public private(set) var currentLogin: String?
```

- [ ] **Step 4: Fetch the login during `load()`**

In `load()`, after `settings = await store.settings()` (line 79), add:

```swift
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
```

- [ ] **Step 5: Add the mutation helpers**

Add these methods to `AppModel` (e.g. next to `markReviewOpened`, around line 514):

```swift
    func markClaudeReviewed(_ id: String) async {
        guard var review = reviews.first(where: { $0.id == id }), review.claudeReviewedAt == nil else { return }
        review.claudeReviewedAt = Date()
        do {
            try await store.upsert(review)
            reviews = await store.allReviews()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func refreshReviewState(for id: String) async {
        guard let login = currentLogin,
              let review = reviews.first(where: { $0.id == id }),
              review.prState != .merged, review.prState != .closed else { return }
        let ref = PRRef(owner: review.owner, repo: review.repo, number: review.number)
        guard let state = try? await client.fetchReviewState(for: ref, login: login) else { return }
        guard var current = reviews.first(where: { $0.id == id }),
              current.approvedByMe != state.approvedByMe || current.prState != state.prState else { return }
        current.approvedByMe = state.approvedByMe
        current.prState = state.prState
        do {
            try await store.upsert(current)
            reviews = await store.allReviews()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func refreshReviewStates() async {
        let ids = reviews
            .filter { $0.prState != .merged && $0.prState != .closed }
            .map(\.id)
        for id in ids {
            await refreshReviewState(for: id)
        }
    }
```

- [ ] **Step 6: Stamp `claudeReviewedAt` when the review-ready notification fires**

In `recomputeStatus(for:now:)`, inside the `if shouldFireReviewReady(...)` block (after `postReviewReadyNotification(for: reviewID, status: newStatus)`, line 411), add:

```swift
            Task { await self.markClaudeReviewed(reviewID) }
```

- [ ] **Step 7: Refresh approval on the discovery poll and on open**

In `startDiscoveryPolling()`, update the task body (lines 109–116) to refresh review states after each discovery pass:

```swift
        discoveryTask = Task { @MainActor in
            await self.discoverNow()
            await self.refreshReviewStates()
            while !Task.isCancelled {
                let intervalNs = UInt64(self.settings.pollIntervalSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                await self.discoverNow()
                await self.refreshReviewStates()
            }
        }
```

In `markReviewOpened(_:)`, after `reviews = await store.allReviews()` (line 510), add:

```swift
            await refreshReviewState(for: id)
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter "loadCachesCurrentLogin|markClaudeReviewedStampsOnce|refreshReviewStateSetsApprovedByMe"`
Expected: PASS (all 3).

- [ ] **Step 9: Run the full Core test suite (no regressions)**

Run: `swift test --package-path Core`
Expected: PASS — all existing tests still green.

- [ ] **Step 10: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat: cache login, stamp claude-reviewed, poll PR approval state" --no-verify
```

---

### Task 5: Sidebar UI — status tag, pulsing dot, Copy Session ID

**Files:**
- Modify: `App/ContentView.swift`

(SwiftUI views are verified by build + manual run, not unit tests.)

- [ ] **Step 1: Import AppKit for clipboard access**

At the top of `App/ContentView.swift` (after line 4, the existing imports), add:

```swift
import AppKit
```

- [ ] **Step 2: Render the status tag from `sidebarStatus`**

In `sidebarRow(for:)`, replace the call on line 97:

```swift
                    stateBadge(for: review.prState)
```

with:

```swift
                    statusBadge(for: review)
```

- [ ] **Step 3: Add the "Copy Session ID" context-menu item**

In the `.contextMenu { ... }` block (lines 111–122), insert at the very top (before the existing Enable/Disable `Button`):

```swift
            Button {
                if let sessionID = review.claudeSessionID {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sessionID, forType: .string)
                }
            } label: {
                Label("Copy Session ID", systemImage: "doc.on.clipboard")
            }
            .disabled(review.claudeSessionID == nil)
            Divider()
```

- [ ] **Step 4: Replace `stateBadge` with `statusBadge` and update `StateBadge` to uppercase**

Replace the whole `stateBadge(for:)` function (lines 197–208) with:

```swift
@ViewBuilder
private func statusBadge(for review: Review) -> some View {
    switch review.sidebarStatus {
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
}
```

Replace the `StateBadge` struct body (lines 210–223) with the uppercase variant:

```swift
private struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.22))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
```

- [ ] **Step 5: Make the `StatusDot` pulse while working**

Replace the `StatusDot` struct (lines 225–248) with:

```swift
private struct StatusDot: View {
    let status: ClaudeStatus?
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isWorking && pulse ? 0.3 : 1.0)
            .animation(
                isWorking ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
            .onAppear { pulse = isWorking }
            .onChange(of: isWorking) { _, working in pulse = working }
    }

    private var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    private var color: Color {
        switch status {
        case .working:
            return .blue
        case .idle:
            return .gray
        case .ready(let code):
            return code == 0 ? .green : .orange
        case .failed:
            return .red
        case .starting, nil:
            return .clear
        }
    }
}
```

- [ ] **Step 6: Build the app to verify it compiles**

Run: `xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual verification**

Run: `osascript -e 'quit app "PRReview"'` then `open "$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -name PRReview.app -path '*/Debug/*' | head -1)"`

Confirm in the running app (dark mode):
- Each sidebar row shows at most one uppercase colored tag (NEW orange, REVIEWED blue, APPROVED green, MERGED purple, CLOSED red, DRAFT gray), and an opened in-progress PR shows no tag.
- A never-opened PR reads NEW even if Claude has finished; opening it flips it to REVIEWED.
- The live status dot pulses while Claude is working and is steady otherwise.
- Right-click a PR → "Copy Session ID"; paste elsewhere to confirm the session UUID copied. The item is disabled for a PR with no Claude session yet.

- [ ] **Step 8: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat: sidebar lifecycle status tags, pulsing status dot, copy session id" --no-verify
```

---

## Self-Review Notes

- **Spec coverage:** New/Reviewed/Approved/Merged/Closed/Draft + precedence (Task 2/5); `claudeReviewedAt` + `approvedByMe` persistence with backward compat (Task 1); current-login cache + review-state poll skipping terminal PRs (Task 3/4); refresh on open (Task 4 Step 7); uppercase tags + adaptive colors + opacity bump (Task 5); pulsing dot (Task 5); Copy Session ID with disabled-when-nil (Task 5). All covered.
- **Type consistency:** `fetchReviewState(for:login:)` returns `GitHubClient.ReviewState`; `AppModel.refreshReviewState(for:)` / `refreshReviewStates()` / `markClaudeReviewed(_:)` and `currentLogin` are used consistently across Task 4. `SidebarStatus` cases match between the enum (Task 2) and the `statusBadge` switch (Task 5).
- **Color note:** SwiftUI `.purple/.green/.orange/.blue/.red/.gray` are adaptive system colors (satisfies the dark-mode requirement); `0.22` tint opacity replaces the old `0.18` for dark-mode visibility.
