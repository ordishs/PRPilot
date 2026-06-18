# Issue Status Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a workflow-status badge (New / In Review / Reviewed / On Hold / Done / Closed) on each assigned issue in the PRPilot sidebar, derived from the Claude session lifecycle with a manual override the user sets via context menu.

**Architecture:** A new `IssueWorkStatus` enum plus a persisted `WorkItem.manualIssueStatus` field. A pure `resolveIssueStatus(...)` function combines the manual override, GitHub closed-state, and the live Claude session state into the displayed status. The sidebar renders it for `.issue` items only; an `AppModel.setIssueStatus` action writes the override.

**Tech Stack:** Swift 6, SwiftPM (`Core/`) for logic, Xcode project (`PRPilot.xcodeproj`, XcodeGen-generated from `project.yml`) for the SwiftUI app, swift-testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- swift-tools-version 6.0; platform macOS 14.
- New model fields decode with `decodeIfPresent` + default `nil`; existing `store.json` loads unchanged. No schema-version bump.
- Status applies to issues only (`WorkItem.category(myLogin:) == .issue`); PR and task badges are unchanged. No GitHub writes.
- Resolution precedence: `prState == .closed` → `.closed` (wins over everything) > manual override > `claudeWorking` → `.inReview` > `claudeReviewedAt != nil` → `.reviewed` > `.new`.
- Manual override persists until cleared ("Clear (Auto)" sets it to `nil`).
- Badge colors: New = orange, In Review = blue, Reviewed = teal, On Hold = gray, Done = purple, Closed = red.
- Commit messages: NO AI/Claude attribution. Use `--no-verify`.
- Core test command: `swift test --package-path Core --filter <name>` (run from repo root `/Users/ordishs/dev/masa.gi/code-reviewer` or the active worktree root).
- App build command: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`.

---

### Task 1: Model — `IssueWorkStatus`, `resolveIssueStatus`, `WorkItem.manualIssueStatus`

**Files:**
- Create: `Core/Sources/PRPilotModels/IssueWorkStatus.swift`
- Modify: `Core/Sources/PRPilotModels/WorkItem.swift`
- Test: `Core/Tests/PRPilotModelsTests/IssueWorkStatusTests.swift` (new)
- Test: `Core/Tests/PRPilotModelsTests/WorkItemTests.swift` (add one test)

**Interfaces:**
- Produces:
  - `enum IssueWorkStatus: String, Codable, Sendable, Equatable, CaseIterable { case new, inReview, reviewed, onHold, done, closed }` with `var displayName: String`.
  - `func resolveIssueStatus(manual: IssueWorkStatus?, prState: PRState?, claudeReviewedAt: Date?, claudeWorking: Bool) -> IssueWorkStatus`
  - `WorkItem.manualIssueStatus: IssueWorkStatus?` (memberwise init param `manualIssueStatus: IssueWorkStatus? = nil`, added LAST so existing positional/labeled call sites are unaffected).

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/PRPilotModelsTests/IssueWorkStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

@Test func closedAlwaysWinsOverManualAndWorking() {
    let s = resolveIssueStatus(manual: .onHold, prState: .closed, claudeReviewedAt: Date(), claudeWorking: true)
    #expect(s == .closed)
}

@Test func manualOverridesDerived() {
    let s = resolveIssueStatus(manual: .onHold, prState: .open, claudeReviewedAt: Date(), claudeWorking: true)
    #expect(s == .onHold)
}

@Test func workingDerivesInReview() {
    let s = resolveIssueStatus(manual: nil, prState: .open, claudeReviewedAt: nil, claudeWorking: true)
    #expect(s == .inReview)
}

@Test func reviewedStampDerivesReviewed() {
    let s = resolveIssueStatus(manual: nil, prState: .open, claudeReviewedAt: Date(), claudeWorking: false)
    #expect(s == .reviewed)
}

@Test func defaultsToNew() {
    let s = resolveIssueStatus(manual: nil, prState: .open, claudeReviewedAt: nil, claudeWorking: false)
    #expect(s == .new)
    let sNilState = resolveIssueStatus(manual: nil, prState: nil, claudeReviewedAt: nil, claudeWorking: false)
    #expect(sNilState == .new)
}

@Test func displayNamesAreHumanReadable() {
    #expect(IssueWorkStatus.onHold.displayName == "On Hold")
    #expect(IssueWorkStatus.inReview.displayName == "In Review")
    #expect(IssueWorkStatus.new.displayName == "New")
    #expect(IssueWorkStatus.reviewed.displayName == "Reviewed")
    #expect(IssueWorkStatus.done.displayName == "Done")
    #expect(IssueWorkStatus.closed.displayName == "Closed")
}
```

Add to `Core/Tests/PRPilotModelsTests/WorkItemTests.swift` (reuse the existing `sampleIssue()` helper already in that file from the issue-management feature):

```swift
@Test func manualIssueStatusRoundTrips() throws {
    var item = sampleIssue()
    item.manualIssueStatus = .onHold
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded.manualIssueStatus == .onHold)
}

@Test func legacyItemDecodesWithNilManualIssueStatus() throws {
    let json = """
    {
      "id": "X", "title": "t", "repoKey": "github.com/o/r",
      "baseBranch": "main", "origin": "added", "autoReview": false,
      "addedAt": "2023-11-14T22:13:20Z", "disabled": false, "viewedFiles": [], "approvedByMe": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.manualIssueStatus == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter closedAlwaysWinsOverManualAndWorking`
Expected: FAIL — `IssueWorkStatus` / `resolveIssueStatus` / `manualIssueStatus` unresolved (compile error).

- [ ] **Step 3: Create `IssueWorkStatus.swift`**

```swift
import Foundation

public enum IssueWorkStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case new
    case inReview
    case reviewed
    case onHold
    case done
    case closed

    public var displayName: String {
        switch self {
        case .new: return "New"
        case .inReview: return "In Review"
        case .reviewed: return "Reviewed"
        case .onHold: return "On Hold"
        case .done: return "Done"
        case .closed: return "Closed"
        }
    }
}

/// Resolves the status shown for an issue work item. Precedence: a GitHub-closed
/// issue always shows `.closed`; otherwise a manual override wins; otherwise the
/// status is derived from the Claude session (`.inReview` while working,
/// `.reviewed` once a turn has completed, else `.new`).
public func resolveIssueStatus(
    manual: IssueWorkStatus?,
    prState: PRState?,
    claudeReviewedAt: Date?,
    claudeWorking: Bool
) -> IssueWorkStatus {
    if prState == .closed { return .closed }
    if let manual { return manual }
    if claudeWorking { return .inReview }
    if claudeReviewedAt != nil { return .reviewed }
    return .new
}
```

- [ ] **Step 4: Add `manualIssueStatus` to `WorkItem.swift`**

Add the stored property immediately after `public var approvedByMe: Bool` (line 24):

```swift
    public var manualIssueStatus: IssueWorkStatus?
```

In `enum CodingKeys`, append `manualIssueStatus` to the last case line so it reads:

```swift
        case addedAt, lastOpenedAt, disabled, viewedFiles, claudeReviewedAt, approvedByMe, manualIssueStatus
```

In the memberwise `init`, add the parameter as the LAST parameter (after `approvedByMe: Bool = false`):

```swift
        approvedByMe: Bool = false,
        manualIssueStatus: IssueWorkStatus? = nil
```

and its assignment after `self.approvedByMe = approvedByMe`:

```swift
        self.manualIssueStatus = manualIssueStatus
```

In `init(from decoder:)`, add this line right after `self.approvedByMe = try c.decodeIfPresent(Bool.self, forKey: .approvedByMe) ?? false` (line 99):

```swift
        self.manualIssueStatus = try c.decodeIfPresent(IssueWorkStatus.self, forKey: .manualIssueStatus)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter IssueWorkStatusTests` then
`swift test --package-path Core --filter manualIssueStatusRoundTrips` then
`swift test --package-path Core --filter legacyItemDecodesWithNilManualIssueStatus`
Expected: PASS for all.

- [ ] **Step 6: Run the full models suite (no regressions)**

Run: `swift test --package-path Core --filter PRPilotModelsTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PRPilotModels/IssueWorkStatus.swift Core/Sources/PRPilotModels/WorkItem.swift Core/Tests/PRPilotModelsTests/IssueWorkStatusTests.swift Core/Tests/PRPilotModelsTests/WorkItemTests.swift
git commit -m "feat(models): add IssueWorkStatus and manual override" --no-verify
```

---

### Task 2: AppModel — `setIssueStatus(_:for:)`

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift` (add one test)

**Interfaces:**
- Consumes: `IssueWorkStatus`, `WorkItem.manualIssueStatus` (Task 1).
- Produces: `AppModel.setIssueStatus(_ status: IssueWorkStatus?, for id: String) async`.

- [ ] **Step 1: Write the failing test**

Add to `Core/Tests/AppCoreTests/AppModelTests.swift`. Build an issue `WorkItem`, seed the store, construct the model with the existing stub fakes (mirror the construction in `addIssueFetchesStoresAndSelects`), then set and clear the status:

```swift
@Test @MainActor func setIssueStatusSetsAndClearsManualOverride() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let issue = WorkItem(
        title: "Login crash",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crash",
        issueRef: IssueRef(owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!, authorLogin: "alice"),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
    try await store.upsertItem(issue)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setIssueStatus(.onHold, for: issue.id)
    #expect(model.reviews.first(where: { $0.id == issue.id })?.manualIssueStatus == .onHold)

    // Persistence: a fresh store over the same file reflects the override.
    let reopened = try ReviewStore(fileURL: url)
    #expect(await reopened.item(id: issue.id)?.manualIssueStatus == .onHold)

    await model.setIssueStatus(nil, for: issue.id)
    #expect(model.reviews.first(where: { $0.id == issue.id })?.manualIssueStatus == nil)
}
```

> `stubClient()`, `tempStoreURL()`, and the `Stub*` fakes already exist in this test file. If `model.load()` needs a network login call, `stubClient()` returns empty output (login resolves to nil) — that is fine for this test; no discovery is triggered by `load()`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path Core --filter setIssueStatusSetsAndClearsManualOverride`
Expected: FAIL — `model.setIssueStatus` does not exist.

- [ ] **Step 3: Add `setIssueStatus` to `AppModel.swift`**

Add immediately after the existing `setReviewDisabled(_:for:)` method (mirror its shape):

```swift
    public func setIssueStatus(_ status: IssueWorkStatus?, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        review.manualIssueStatus = status
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path Core --filter setIssueStatusSetsAndClearsManualOverride`
Expected: PASS.

- [ ] **Step 5: Run the full AppCore suite (no regressions)**

Run: `swift test --package-path Core --filter AppCoreTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): add setIssueStatus to persist manual override" --no-verify
```

---

### Task 3: UI — issue status badge + "Set Status" context submenu

**Files:**
- Modify: `App/ContentView.swift`

**Interfaces:**
- Consumes: `resolveIssueStatus(...)`, `IssueWorkStatus`, `WorkItem.manualIssueStatus` (Task 1); `AppModel.setIssueStatus` (Task 2); existing `StateBadge`, `model.claudeStatuses`, `model.currentLogin`.

- [ ] **Step 1: Replace `statusBadge(for:)` to branch on issue category**

In `App/ContentView.swift`, replace the `statusBadge(for:)` method header and opening so issues use a dedicated badge, and add the `issueStatusBadge(for:)` helper right after it. The existing `switch review.sidebarStatus { … }` body stays inside the `else`:

```swift
    @ViewBuilder
    private func statusBadge(for review: WorkItem) -> some View {
        if review.category(myLogin: model.currentLogin) == .issue {
            issueStatusBadge(for: review)
        } else {
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
    }

    @ViewBuilder
    private func issueStatusBadge(for review: WorkItem) -> some View {
        let status = resolveIssueStatus(
            manual: review.manualIssueStatus,
            prState: review.prState,
            claudeReviewedAt: review.claudeReviewedAt,
            claudeWorking: model.claudeStatuses[review.id] == .working
        )
        switch status {
        case .new: StateBadge(text: "New", color: .orange)
        case .inReview: StateBadge(text: "In Review", color: .blue)
        case .reviewed: StateBadge(text: "Reviewed", color: .teal)
        case .onHold: StateBadge(text: "On Hold", color: .gray)
        case .done: StateBadge(text: "Done", color: .purple)
        case .closed: StateBadge(text: "Closed", color: .red)
        }
    }
```

> Verify the `switch review.sidebarStatus` body you place in the `else` matches the file's current cases exactly (`.merged/.closed/.approved/.new/.reviewed/.draft/.open`). Copy them from the existing method — do not invent cases.

- [ ] **Step 2: Add the "Set Status" submenu to the context menu**

In `sidebarRow(for:)`'s `.contextMenu { … }`, add this block as the FIRST item (immediately inside the `.contextMenu {`), before the existing `if review.category(...) != .reviewRequest …` block:

```swift
            if review.category(myLogin: model.currentLogin) == .issue {
                Menu {
                    Button("On Hold") { Task { await model.setIssueStatus(.onHold, for: review.id) } }
                    Button("Done") { Task { await model.setIssueStatus(.done, for: review.id) } }
                    Button("In Review") { Task { await model.setIssueStatus(.inReview, for: review.id) } }
                    Button("Reviewed") { Task { await model.setIssueStatus(.reviewed, for: review.id) } }
                    Button("New") { Task { await model.setIssueStatus(.new, for: review.id) } }
                    Divider()
                    Button("Clear (Auto)") { Task { await model.setIssueStatus(nil, for: review.id) } }
                } label: {
                    Label("Set Status", systemImage: "tag")
                }
                Divider()
            }
```

- [ ] **Step 3: Build the app**

Run: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual smoke check**

Launch the app. For an issue in the sidebar, confirm a colored status badge appears (New/In Review/Reviewed as the Claude session progresses). Right-click an issue → "Set Status ▸ On Hold"; the badge changes to a gray "On Hold" and persists across relaunch. "Set Status ▸ Clear (Auto)" reverts it to the derived status. Confirm PR rows still show their original badges (Merged/Approved/New/etc.) and have no "Set Status" submenu.

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(sidebar): show issue status badge with manual override menu" --no-verify
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

- Spec "Status set" + "Resolution logic" → Task 1 (`IssueWorkStatus`, `resolveIssueStatus`, truth-table tests).
- Spec "Model" (`manualIssueStatus`, backward-compat) → Task 1 (field + codable + legacy-decode tests, no schema bump).
- Spec "AppModel" (`setIssueStatus`) → Task 2.
- Spec "UI" (badge for issues, colors, "Set Status ▸" submenu, PR/task untouched) → Task 3.
- Spec "Testing" → resolveIssueStatus truth table (Task 1), codable round-trip + legacy decode (Task 1), setIssueStatus set/clear/persist (Task 2), UI via build + manual (Task 3).
- Naming consistency: `IssueWorkStatus`, `manualIssueStatus`, `resolveIssueStatus`, `setIssueStatus`, `issueStatusBadge` used identically across tasks. Colors match the Global Constraints line.
