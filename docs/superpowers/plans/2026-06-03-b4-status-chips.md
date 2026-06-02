# B4 — PR Status Chips (CI / behind / changes) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Show objective PR health in the sidebar for every PR: **CI** (✓ passing / ✗ failing / ◷ pending), **out-of-date with base** ("behind"), and **changes requested**. Derived at runtime from `gh`, never persisted.

**Architecture:** A new `PRStatus` value type (PRPilotModels) with pure aggregation helpers (`aggregateCI`, `readiness`). `GitHubClient.fetchPRStatus(for:)` runs `gh pr view <n> --repo o/r --json statusCheckRollup,mergeStateStatus,isDraft,reviewDecision` and maps it to `PRStatus`. `AppModel` holds a non-persisted `prStatuses: [String: PRStatus]` (like `claudeStatuses`), refreshed for each open PR during the existing `refreshReviewState` poll path; cleared on remove. `ContentView`'s row renders chips from `model.prStatuses[id]`.

**Why these three chips (not all of readiness):** the existing lifecycle badge (`sidebarStatus`) already shows Draft / Approved / New / Reviewed / Merged / Closed. CI and "behind" are entirely new signals; "changes requested" (PR `reviewDecision`) is the one readiness state not already surfaced. Draft/approved stay on the lifecycle badge — no duplicate chips.

**Scope (deferred):** Local status for pre-PR **tasks** (commits-ahead / dirty worktree) is deferred — it needs a git-on-worktree call and is secondary to the PR chips the user asked for; note it for a later pass. Tasks simply show no PR chips (they have no `prRef`).

**Tech Stack:** Swift / SwiftUI; Apple Swift Testing; XcodeGen app target.
**Build/test:** `swift test --package-path Core`; `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`.
**Conventions:** No comments unless surrounding code has them; `--no-verify`; no AI attribution.

---

## File Structure

**New:**
- `Core/Sources/PRPilotModels/PRStatus.swift` — `CIStatus`, `ReviewReadiness`, `CICheck`, `PRStatus` + aggregation.
- `Core/Tests/PRPilotModelsTests/PRStatusTests.swift` — aggregation tables.

**Modify:**
- `Core/Sources/GitHubKit/GitHubClient.swift` — `fetchPRStatus` + `GHStatusPayload`.
- `Core/Tests/GitHubKitTests/GitHubClientTests.swift` — canned-JSON fetchPRStatus tests.
- `Core/Sources/AppCore/AppModel.swift` — `prStatuses` dict; fetch in `refreshReviewState`; clear on remove.
- `Core/Tests/AppCoreTests/AppModelTests.swift` — prStatuses populated on refresh.
- `App/ContentView.swift` — status chips in the row.

---

## Task 1: `PRStatus` model + aggregation

**Files:** Create `Core/Sources/PRPilotModels/PRStatus.swift`, `Core/Tests/PRPilotModelsTests/PRStatusTests.swift`.

- [ ] **Step 1: Failing tests** — create `PRStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

@Test func ciNoneWhenNoChecks() {
    #expect(PRStatus.aggregateCI([]) == .none)
}

@Test func ciPassingWhenAllSucceed() {
    let checks = [
        CICheck(status: "COMPLETED", conclusion: "SUCCESS"),
        CICheck(state: "SUCCESS"),
        CICheck(status: "COMPLETED", conclusion: "NEUTRAL"),
    ]
    #expect(PRStatus.aggregateCI(checks) == .passing)
}

@Test func ciFailingDominates() {
    let checks = [
        CICheck(status: "COMPLETED", conclusion: "SUCCESS"),
        CICheck(status: "COMPLETED", conclusion: "FAILURE"),
        CICheck(state: "PENDING"),
    ]
    #expect(PRStatus.aggregateCI(checks) == .failing)
}

@Test func ciFailingFromStatusContextErrorState() {
    #expect(PRStatus.aggregateCI([CICheck(state: "ERROR")]) == .failing)
}

@Test func ciPendingWhenAnyInProgressAndNoFailure() {
    let checks = [
        CICheck(status: "COMPLETED", conclusion: "SUCCESS"),
        CICheck(status: "IN_PROGRESS"),
    ]
    #expect(PRStatus.aggregateCI(checks) == .pending)
}

@Test func ciPendingFromStatusContextPending() {
    #expect(PRStatus.aggregateCI([CICheck(state: "PENDING")]) == .pending)
}

@Test func readinessDraftBeatsDecision() {
    #expect(PRStatus.readiness(isDraft: true, reviewDecision: "APPROVED") == .draft)
}

@Test func readinessMapsReviewDecision() {
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "APPROVED") == .approved)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "CHANGES_REQUESTED") == .changesRequested)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "REVIEW_REQUIRED") == .reviewRequired)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: nil) == .none)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "") == .none)
}

@Test func prStatusRoundTripsThroughCodable() throws {
    let s = PRStatus(ci: .passing, isBehind: true, readiness: .changesRequested)
    #expect(try JSONDecoder().decode(PRStatus.self, from: JSONEncoder().encode(s)) == s)
}
```

- [ ] **Step 2: Run → FAIL**: `swift test --package-path Core --filter PRStatus`

- [ ] **Step 3: Implement** — create `PRStatus.swift`:

```swift
import Foundation

public enum CIStatus: String, Codable, Sendable, Equatable {
    case passing, failing, pending, none
}

public enum ReviewReadiness: String, Codable, Sendable, Equatable {
    case draft, approved, changesRequested, reviewRequired, none
}

/// One entry from `gh pr view --json statusCheckRollup`. A CheckRun carries `status`
/// (+ `conclusion` once COMPLETED); a StatusContext carries `state`.
public struct CICheck: Sendable, Equatable {
    public var status: String?
    public var conclusion: String?
    public var state: String?
    public init(status: String? = nil, conclusion: String? = nil, state: String? = nil) {
        self.status = status
        self.conclusion = conclusion
        self.state = state
    }
}

public struct PRStatus: Codable, Sendable, Equatable {
    public var ci: CIStatus
    public var isBehind: Bool
    public var readiness: ReviewReadiness

    public init(ci: CIStatus, isBehind: Bool, readiness: ReviewReadiness) {
        self.ci = ci
        self.isBehind = isBehind
        self.readiness = readiness
    }

    public static func aggregateCI(_ checks: [CICheck]) -> CIStatus {
        var anyChecked = false
        var anyPending = false
        for c in checks {
            if let conclusion = c.conclusion, !conclusion.isEmpty {
                anyChecked = true
                switch conclusion.uppercased() {
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE":
                    return .failing
                default:
                    break // SUCCESS, NEUTRAL, SKIPPED → ok
                }
            } else if let status = c.status, !status.isEmpty {
                anyChecked = true
                if status.uppercased() != "COMPLETED" { anyPending = true } // QUEUED, IN_PROGRESS
            } else if let state = c.state, !state.isEmpty {
                anyChecked = true
                switch state.uppercased() {
                case "FAILURE", "ERROR":
                    return .failing
                case "PENDING", "EXPECTED":
                    anyPending = true
                default:
                    break // SUCCESS
                }
            }
        }
        if !anyChecked { return .none }
        return anyPending ? .pending : .passing
    }

    public static func readiness(isDraft: Bool, reviewDecision: String?) -> ReviewReadiness {
        if isDraft { return .draft }
        switch reviewDecision?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return .none
        }
    }
}
```

- [ ] **Step 4: Run → PASS**: `swift test --package-path Core --filter PRStatus`
- [ ] **Step 5: Commit**
```bash
git add Core/Sources/PRPilotModels/PRStatus.swift Core/Tests/PRPilotModelsTests/PRStatusTests.swift
git commit -m "feat(models): add PRStatus with CI + readiness aggregation" --no-verify
```

---

## Task 2: `GitHubClient.fetchPRStatus`

**Files:** `Core/Sources/GitHubKit/GitHubClient.swift`, `Core/Tests/GitHubKitTests/GitHubClientTests.swift`.

- [ ] **Step 1: Failing tests** (mirror the file's existing `StubRunner`-driven `fetchReviewState`/`fetchReview` tests). Add to `GitHubClientTests.swift`:

```swift
@Test func fetchPRStatusParsesChecksBehindAndDecision() async throws {
    let json = """
    {
      "statusCheckRollup": [
        {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
        {"__typename":"StatusContext","state":"PENDING"}
      ],
      "mergeStateStatus": "BEHIND",
      "isDraft": false,
      "reviewDecision": "CHANGES_REQUESTED"
    }
    """
    let client = GitHubClient(runner: StubRunner(results: [CommandResult(exitCode: 0, standardOutput: json, standardError: "")]), ghPath: "/usr/bin/gh")
    let status = try await client.fetchPRStatus(for: PRLocator(owner: "o", repo: "r", number: 1))
    #expect(status.ci == .pending)
    #expect(status.isBehind == true)
    #expect(status.readiness == .changesRequested)
}

@Test func fetchPRStatusHandlesNullRollupAndCleanMerge() async throws {
    let json = """
    { "statusCheckRollup": null, "mergeStateStatus": "CLEAN", "isDraft": true, "reviewDecision": null }
    """
    let client = GitHubClient(runner: StubRunner(results: [CommandResult(exitCode: 0, standardOutput: json, standardError: "")]), ghPath: "/usr/bin/gh")
    let status = try await client.fetchPRStatus(for: PRLocator(owner: "o", repo: "r", number: 1))
    #expect(status.ci == .none)
    #expect(status.isBehind == false)
    #expect(status.readiness == .draft)
}
```
(Match the actual `StubRunner` / `CommandResult` initializer signatures used elsewhere in the file — read an existing `fetchReviewState` test and copy its construction style exactly.)

- [ ] **Step 2: Run → FAIL**.

- [ ] **Step 3: Implement** — add to `GitHubClient` (after `fetchReviewState`):

```swift
    public func fetchPRStatus(for ref: PRLocator) async throws -> PRStatus {
        let result = try await runner.run(
            executable: ghPath,
            arguments: prViewArguments(ref: ref, fields: "statusCheckRollup,mergeStateStatus,isDraft,reviewDecision")
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let payload: GHStatusPayload
        do {
            payload = try JSONDecoder().decode(GHStatusPayload.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let checks = (payload.statusCheckRollup ?? []).map {
            CICheck(status: $0.status, conclusion: $0.conclusion, state: $0.state)
        }
        return PRStatus(
            ci: PRStatus.aggregateCI(checks),
            isBehind: payload.mergeStateStatus == "BEHIND",
            readiness: PRStatus.readiness(isDraft: payload.isDraft, reviewDecision: payload.reviewDecision)
        )
    }
```

And add the payload struct near `GHReviewStatePayload`:

```swift
struct GHStatusPayload: Decodable {
    struct Check: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }
    let statusCheckRollup: [Check]?
    let mergeStateStatus: String?
    let isDraft: Bool
    let reviewDecision: String?
}
```

- [ ] **Step 4: Run → PASS**: `swift test --package-path Core --filter fetchPRStatus`
- [ ] **Step 5: Commit**
```bash
git add Core/Sources/GitHubKit/GitHubClient.swift Core/Tests/GitHubKitTests/GitHubClientTests.swift
git commit -m "feat(github): fetchPRStatus for CI/behind/readiness chips" --no-verify
```

---

## Task 3: `AppModel.prStatuses` + refresh

**Files:** `Core/Sources/AppCore/AppModel.swift`, `Core/Tests/AppCoreTests/AppModelTests.swift`.

- [ ] **Step 1: Add the runtime dict**

Next to `public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]`:
```swift
    public private(set) var prStatuses: [String: PRStatus] = [:]
```

- [ ] **Step 2: Fetch in `refreshReviewState`**

At the END of `refreshReviewState(for id:)` (after the existing review-state update block), fetch + store the volatile status. Because the existing method early-returns when prState/approvedByMe are unchanged, restructure so the status fetch always runs for an open PR. Replace `refreshReviewState(for:)` with:

```swift
    func refreshReviewState(for id: String) async {
        guard let login = currentLogin,
              let review = reviews.first(where: { $0.id == id }),
              review.prState != .merged, review.prState != .closed,
              let r = review.prRef else { return }
        let ref = PRLocator(owner: r.owner, repo: r.repo, number: r.number)

        if let state = try? await client.fetchReviewState(for: ref, login: login),
           var current = reviews.first(where: { $0.id == id }),
           current.approvedByMe != state.approvedByMe || current.prState != state.prState {
            current.approvedByMe = state.approvedByMe
            current.prState = state.prState
            do {
                try await store.upsertItem(current)
                reviews = await store.allItems()
            } catch {
                errorMessage = String(describing: error)
            }
        }

        if let status = try? await client.fetchPRStatus(for: ref) {
            prStatuses[id] = status
        }
    }
```
(`refreshReviewStates()` is unchanged — it already iterates open items and calls this.)

- [ ] **Step 3: Clear on remove**

In `terminateClaudeSession(for id:)` (or wherever `claudeStatuses.removeValue(forKey: id)` happens on removal — confirm the exact method that cleans up per-item dicts on `removeReview`), add:
```swift
        prStatuses.removeValue(forKey: id)
```
(If the cleanup for `removeReview` is in a different method than session-clear, add it specifically to the `removeReview` path so a removed item's status is dropped. Read `removeReview` + `terminateClaudeSession` and place it where the other per-item dicts are cleared on removal.)

- [ ] **Step 4: Test** (`AppModelTests.swift`, mirror the discovery/refresh stub setup)

```swift
@Test func refreshPopulatesPRStatus() async {
    // Seed one open PR WorkItem (prRef o/r#1) into the store; currentLogin set.
    // Queue the StubRunner so refreshReviewState's calls resolve: fetchReviewState JSON
    // (state/isDraft/reviews) THEN fetchPRStatus JSON (statusCheckRollup/mergeStateStatus/isDraft/reviewDecision)
    // with a failing check + BEHIND.
    // await model.refreshReviewState(for: <id>)   // or refreshReviewStates()
    // #expect(model.prStatuses[<id>]?.ci == .failing)
    // #expect(model.prStatuses[<id>]?.isBehind == true)
}
```
Read how existing refresh tests queue `StubRunner` results (order: the model's `refreshReviewState` calls `fetchReviewState` first, then `fetchPRStatus`, so queue two results in that order; plus any `fetchCurrentLogin` if `currentLogin` is nil — set `currentLogin` beforehand or queue it). Match the file's patterns; keep all existing tests green (the new `fetchPRStatus` call adds one stub consumption per open PR per refresh — adjust any existing refresh test's queue length if it now under-feeds).

- [ ] **Step 5:** `swift test --package-path Core` → all pass (report count).
- [ ] **Step 6: Commit**
```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): track volatile PR status per item on refresh" --no-verify
```

---

## Task 4: Status chips in the sidebar row

**Files:** `App/ContentView.swift`.

- [ ] **Step 1: Render chips in `sidebarRow`**

In `sidebarRow(for:)`, after the `Text("\(review.owner)/\(review.repo) · \(review.author ?? "")")` subtitle line, add a chips row driven by `model.prStatuses[review.id]`:

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
                    }
                }
```
`StateBadge` is the existing private chip view in this file (text uppercased, colored capsule) — reuse it.

- [ ] **Step 2: Build the app**: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build` → BUILD SUCCEEDED.
- [ ] **Step 3: Commit**
```bash
git add App/ContentView.swift
git commit -m "feat(ui): CI / behind / changes status chips in the sidebar" --no-verify
```

---

## Task 5: Verify

- [ ] **Step 1:** `swift test --package-path Core` → all pass.
- [ ] **Step 2:** `xcodegen generate && xcodebuild ... build` → BUILD SUCCEEDED.
- [ ] **Step 3 (controller, optional manual):** Launch the app on the teranode data; after a discovery poll, confirm open PRs show CI/behind/changes chips matching `gh pr view <n> --json statusCheckRollup,mergeStateStatus,reviewDecision`. (Read-only; controller decides.)

---

## Self-Review

**Spec coverage:** CI chip (statusCheckRollup aggregation) ✓; out-of-date chip (mergeStateStatus BEHIND) ✓; readiness — changes-requested chip ✓ (draft/approved already on the lifecycle badge, documented); derived/not-persisted ✓ (runtime `prStatuses` dict). Deferred (documented): task local ahead/dirty status.

**Placeholder scan:** Test bodies for Task 3 are described with concrete assertions + stub-ordering guidance (the implementer adapts to the existing StubRunner harness) — not a TBD; the queue order (fetchReviewState then fetchPRStatus) is specified.

**Type consistency:** `PRStatus {ci, isBehind, readiness}`, `CIStatus`, `ReviewReadiness`, `CICheck`, `aggregateCI`, `readiness`; `GitHubClient.fetchPRStatus(for:) -> PRStatus`; `AppModel.prStatuses: [String: PRStatus]`. Chips reuse the existing `StateBadge`.

**Polling cost:** adds one `gh pr view` per open PR per poll (on top of the existing `fetchReviewState` call). Acceptable at single-user scale; a combined single-call fetch is a possible later optimization (carry-forward).

---

## Next plan

**B5 — Rebase + Push:** context actions on editable My Work items; local rebase (conflict flow), separate force-with-lease push; **and the refresh guard** (stop `refreshWorktree` from `git reset --hard`-ing worktrees with unpushed local commits).
