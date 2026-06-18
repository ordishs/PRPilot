# Issue Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let PRPilot discover GitHub issues assigned to the user and, on first sight, clone the repo, create a branch worktree, show the issue in the GitHub pane, and start a Claude `/start-issue` session.

**Architecture:** An assigned issue is a third variant of the existing `WorkItem` (it carries a new `issueRef` and has `prRef == nil`). It reuses the existing clone-on-demand → branch-worktree → Claude-session pipeline that freeform "tasks" already use. New machinery is limited to: an issue reference on the model, issue discovery in `GitHubKit`, issue-specific launch in `ClaudeSessionKit`, a new sidebar section, and an "Add Issue by URL" flow.

**Tech Stack:** Swift 6, SwiftPM (`Core/`) for logic, Xcode project (`PRPilot.xcodeproj`) for the SwiftUI app, swift-testing (`import Testing`, `@Test`, `#expect`), `gh` CLI, `git` worktrees.

## Global Constraints

- swift-tools-version 6.0; platform macOS 14 (`.macOS(.v14)`).
- All new model fields decode with `decodeIfPresent` + defaults — existing `store.json` must load unchanged. **No schema-version bump** (stays `3`).
- `WorkItem.number` MUST remain `prRef?.number` (nil for issues) — this is what routes issues down the new-branch worktree path instead of `refs/pull/N`.
- Issue open/closed state is stored in the existing `prState` field (`OPEN → .open`, `CLOSED → .closed`).
- Auto-start on discovery is unconditional (NOT gated by `settings.autoLoad`); `issuesEnabled` is the gate.
- Claude behavior for issues is evaluate-only: `/start-issue <issueNumber>`.
- No AI/Claude attribution in commit messages (user global rule).
- Core test command: `swift test --package-path Core --filter <name>`.
- App build command: `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`.

---

### Task 1: `IssueRef` + `WorkItem` issue support

**Files:**
- Create: `Core/Sources/PRPilotModels/IssueRef.swift`
- Modify: `Core/Sources/PRPilotModels/WorkItemCategory.swift`
- Modify: `Core/Sources/PRPilotModels/WorkItem.swift`
- Test: `Core/Tests/PRPilotModelsTests/WorkItemTests.swift`

**Interfaces:**
- Produces:
  - `struct IssueRef: Codable, Sendable, Equatable { owner, repo: String; number: Int; url: URL; authorLogin: String }`
  - `WorkItem.issueRef: IssueRef?` (memberwise init param `issueRef: IssueRef? = nil`, placed after `prState`)
  - `WorkItemCategory.issue`
  - `WorkItem.category(myLogin:) -> WorkItemCategory` (returns `.issue` when `prRef == nil && issueRef != nil`)
  - `WorkItem.url: URL?` → `prRef?.url ?? issueRef?.url`
  - `WorkItem.issueNumber: Int?` → `issueRef?.number`
  - `WorkItem.displayNumber: Int?` → `prRef?.number ?? issueRef?.number`
  - `WorkItem.author: String?` → `prRef?.authorLogin ?? issueRef?.authorLogin`
  - `static WorkItem.slug(_:maxLength:) -> String`
  - `static WorkItem.issueBranchName(number:title:) -> String`

- [ ] **Step 1: Write the failing tests**

Add to `Core/Tests/PRPilotModelsTests/WorkItemTests.swift`:

```swift
private func sampleIssue() -> WorkItem {
    WorkItem(
        title: "Login crashes on empty password",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crashes-on-empty-password",
        issueRef: IssueRef(
            owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!,
            authorLogin: "alice"
        ),
        prState: .open,
        origin: .discovered,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func issueItemCategoryIsIssue() {
    #expect(sampleIssue().category(myLogin: "ordishs") == .issue)
    #expect(sampleIssue().category(myLogin: nil) == .issue)
}

@Test func issueItemAccessors() {
    let item = sampleIssue()
    #expect(item.number == nil)
    #expect(item.issueNumber == 42)
    #expect(item.displayNumber == 42)
    #expect(item.url?.absoluteString == "https://github.com/bsv-blockchain/teranode/issues/42")
    #expect(item.author == "alice")
}

@Test func issueBranchNameSlugsTitle() {
    #expect(WorkItem.issueBranchName(number: 42, title: "Login crashes on empty password!")
        == "issue-42-login-crashes-on-empty-password")
    #expect(WorkItem.issueBranchName(number: 7, title: "   ")
        == "issue-7")
    let long = WorkItem.issueBranchName(number: 9, title: String(repeating: "ab cd ", count: 20))
    #expect(long.hasPrefix("issue-9-"))
    #expect(!long.hasSuffix("-"))
}

@Test func issueItemCodableRoundTrips() throws {
    let item = sampleIssue()
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded == item)
    #expect(decoded.issueRef?.number == 42)
}

@Test func legacyItemWithoutIssueRefDecodes() throws {
    let json = """
    {
      "id": "X", "title": "centrifuge fix", "repoKey": "github.com/bsv-blockchain/teranode",
      "baseBranch": "main", "origin": "added", "autoReview": false,
      "addedAt": "2023-11-14T22:13:20Z", "disabled": false, "viewedFiles": [], "approvedByMe": false
    }
    """
    let decoded = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.issueRef == nil)
    #expect(decoded.category(myLogin: nil) == .task)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter issueItemCategoryIsIssue`
Expected: FAIL — `IssueRef` / `issueRef` / `.issue` unresolved (compile error).

- [ ] **Step 3: Create `IssueRef.swift`**

```swift
import Foundation

public struct IssueRef: Codable, Sendable, Equatable {
    public var owner: String
    public var repo: String
    public var number: Int
    public var url: URL
    public var authorLogin: String

    public init(owner: String, repo: String, number: Int, url: URL, authorLogin: String) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.authorLogin = authorLogin
    }
}
```

- [ ] **Step 4: Add `.issue` to `WorkItemCategory.swift`**

```swift
public enum WorkItemCategory: Sendable, Equatable {
    case task
    case myPR
    case reviewRequest
    case issue
}
```

- [ ] **Step 5: Modify `WorkItem.swift`**

In the stored properties, add after `public var prState: PRState?`:

```swift
    public var issueRef: IssueRef?
```

In `enum CodingKeys`, add `issueRef`:

```swift
        case id, title, repoKey, baseBranch, headBranch, worktreePath, prRef, prState, issueRef
        case origin, closingIssueNumber, notes, claudeFlags, claudeSessionID, autoReview
        case addedAt, lastOpenedAt, disabled, viewedFiles, claudeReviewedAt, approvedByMe
```

In the memberwise `init`, add the parameter after `prState: PRState? = nil,`:

```swift
        issueRef: IssueRef? = nil,
```

and the assignment after `self.prState = prState`:

```swift
        self.issueRef = issueRef
```

In `init(from decoder:)`, add this line alongside the other top-level `decodeIfPresent` calls (e.g. right after `self.worktreePath = try c.decodeIfPresent(...)`):

```swift
        self.issueRef = try c.decodeIfPresent(IssueRef.self, forKey: .issueRef)
```

Replace `category(myLogin:)` with:

```swift
    public func category(myLogin: String?) -> WorkItemCategory {
        if let prRef {
            if let myLogin, prRef.authorLogin.caseInsensitiveCompare(myLogin) == .orderedSame {
                return .myPR
            }
            return .reviewRequest
        }
        if issueRef != nil { return .issue }
        return .task
    }
```

Replace the accessor block (currently `owner`/`repo`/`number`/`url`/`author`) with:

```swift
    public var owner: String { WorkItem.ownerRepo(from: repoKey).owner }
    public var repo: String { WorkItem.ownerRepo(from: repoKey).repo }
    public var number: Int? { prRef?.number }
    public var issueNumber: Int? { issueRef?.number }
    public var displayNumber: Int? { prRef?.number ?? issueRef?.number }
    public var url: URL? { prRef?.url ?? issueRef?.url }
    public var author: String? { prRef?.authorLogin ?? issueRef?.authorLogin }
```

Add these statics inside `WorkItem` (e.g. just above `static func ownerRepo`):

```swift
    public static func slug(_ text: String, maxLength: Int = 40) -> String {
        var out = ""
        var lastDash = false
        for ch in text.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let dashes = CharacterSet(charactersIn: "-")
        let trimmed = out.trimmingCharacters(in: dashes)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: dashes)
    }

    public static func issueBranchName(number: Int, title: String) -> String {
        let s = slug(title)
        return s.isEmpty ? "issue-\(number)" : "issue-\(number)-\(s)"
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter "issueItem"` then
`swift test --package-path Core --filter issueBranchNameSlugsTitle` and
`swift test --package-path Core --filter legacyItemWithoutIssueRefDecodes`
Expected: PASS for all.

- [ ] **Step 7: Run the full models suite (guard against regressions)**

Run: `swift test --package-path Core --filter PRPilotModelsTests`
Expected: PASS (existing `WorkItemMigrationTests`, `ModelsTests`, etc. still green).

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/PRPilotModels/IssueRef.swift Core/Sources/PRPilotModels/WorkItem.swift Core/Sources/PRPilotModels/WorkItemCategory.swift Core/Tests/PRPilotModelsTests/WorkItemTests.swift
git commit -m "feat(models): add IssueRef and issue WorkItem support" --no-verify
```

---

### Task 2: `sidebarSections` issue bucket

**Files:**
- Modify: `Core/Sources/PRPilotModels/SidebarSections.swift`
- Test: `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift`

**Interfaces:**
- Consumes: `WorkItemCategory.issue`, `WorkItem.category(myLogin:)` (Task 1)
- Produces: `SidebarSections.issues: [WorkItem]`; init becomes `init(myWork:reviewRequests:issues:)`

- [ ] **Step 1: Write the failing test**

Add to `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift`:

```swift
@Test func issuesGoIntoIssuesBucket() {
    let issue = WorkItem(
        title: "bug", repoKey: "github.com/o/r", baseBranch: "main",
        headBranch: "issue-1-bug",
        issueRef: IssueRef(owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/issues/1")!, authorLogin: "alice"),
        prState: .open, origin: .discovered, addedAt: Date()
    )
    let task = WorkItem(
        title: "feat/x", repoKey: "github.com/o/r", baseBranch: "main",
        headBranch: "feat/x", origin: .added, addedAt: Date()
    )
    let sections = sidebarSections(items: [issue, task], myLogin: "me", sort: .recent)
    #expect(sections.issues.map(\.id) == [issue.id])
    #expect(sections.myWork.map(\.id) == [task.id])
    #expect(sections.reviewRequests.isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path Core --filter issuesGoIntoIssuesBucket`
Expected: FAIL — `sections.issues` does not exist (compile error).

- [ ] **Step 3: Modify `SidebarSections.swift`**

Replace the struct and function with:

```swift
public struct SidebarSections: Sendable, Equatable {
    public let myWork: [WorkItem]
    public let reviewRequests: [WorkItem]
    public let issues: [WorkItem]

    public init(myWork: [WorkItem], reviewRequests: [WorkItem], issues: [WorkItem]) {
        self.myWork = myWork
        self.reviewRequests = reviewRequests
        self.issues = issues
    }
}

public func sidebarSections(items: [WorkItem], myLogin: String?, sort: SidebarSort) -> SidebarSections {
    var myWork: [WorkItem] = []
    var reviews: [WorkItem] = []
    var issues: [WorkItem] = []
    for item in items {
        switch item.category(myLogin: myLogin) {
        case .task, .myPR:
            myWork.append(item)
        case .reviewRequest:
            reviews.append(item)
        case .issue:
            issues.append(item)
        }
    }
    return SidebarSections(
        myWork: sortWorkItems(myWork, by: sort),
        reviewRequests: sortWorkItems(reviews, by: sort),
        issues: sortWorkItems(issues, by: sort)
    )
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path Core --filter issuesGoIntoIssuesBucket`
Expected: PASS

- [ ] **Step 5: Run the existing sidebar suite**

Run: `swift test --package-path Core --filter SidebarSectionsTests`
Expected: PASS (existing tests that construct `SidebarSections` still compile/run; if any constructed it directly with two args, update them to pass `issues: []`).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PRPilotModels/SidebarSections.swift Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift
git commit -m "feat(sidebar): add issues bucket to sidebarSections" --no-verify
```

---

### Task 3: `IssueLocator`

**Files:**
- Create: `Core/Sources/GitHubKit/IssueLocator.swift`
- Test: `Core/Tests/GitHubKitTests/IssueLocatorTests.swift`

**Interfaces:**
- Produces: `struct IssueLocator: Sendable, Equatable { owner, repo: String; number: Int }` with `static func parse(_:) throws -> IssueLocator` (throws `GitHubError.invalidURL` on non-issue/non-github URLs).

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/GitHubKitTests/IssueLocatorTests.swift`:

```swift
import Testing
import Foundation
@testable import GitHubKit

@Test func issueLocatorParsesIssueURL() throws {
    let loc = try IssueLocator.parse("https://github.com/bsv-blockchain/teranode/issues/42")
    #expect(loc.owner == "bsv-blockchain")
    #expect(loc.repo == "teranode")
    #expect(loc.number == 42)
}

@Test func issueLocatorRejectsPullURL() {
    #expect(throws: GitHubError.self) {
        try IssueLocator.parse("https://github.com/o/r/pull/7")
    }
}

@Test func issueLocatorRejectsNonGitHub() {
    #expect(throws: GitHubError.self) {
        try IssueLocator.parse("https://gitlab.com/o/r/issues/7")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path Core --filter issueLocatorParsesIssueURL`
Expected: FAIL — `IssueLocator` unresolved.

- [ ] **Step 3: Create `IssueLocator.swift`**

```swift
import Foundation

public struct IssueLocator: Sendable, Equatable {
    public var owner: String
    public var repo: String
    public var number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    public static func parse(_ urlString: String) throws -> IssueLocator {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw GitHubError.invalidURL(urlString)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "issues", let number = Int(parts[3]), number > 0 else {
            throw GitHubError.invalidURL(urlString)
        }
        return IssueLocator(owner: parts[0], repo: parts[1], number: number)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter IssueLocator`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/GitHubKit/IssueLocator.swift Core/Tests/GitHubKitTests/IssueLocatorTests.swift
git commit -m "feat(github): add IssueLocator URL parser" --no-verify
```

---

### Task 4: `GitHubClient.searchIssues` + `fetchIssue`

**Files:**
- Modify: `Core/Sources/GitHubKit/GitHubClient.swift`
- Test: `Core/Tests/GitHubKitTests/GitHubClientTests.swift`

**Interfaces:**
- Consumes: `IssueLocator` (Task 3); `WorkItem.issueBranchName` (Task 1); existing `fetchDefaultBase` (calls `gh repo view`).
- Produces:
  - `struct IssueHit: Sendable, Equatable { owner, repo: String; number: Int; title, url, authorLogin, state: String; var id: String; var locator: IssueLocator }` where `id == "<owner>/<repo>/issues/<number>"`
  - `GitHubClient.searchIssues(query: String) async throws -> [IssueHit]`
  - `GitHubClient.fetchIssue(for: IssueLocator, origin: ReviewOrigin = .added, now: Date = Date()) async throws -> WorkItem`
  - `static GitHubClient.mapIssueState(state: String) -> PRState` (`CLOSED → .closed`, else `.open`)

- [ ] **Step 1: Write the failing tests**

The existing test file defines a `RecordingRunner` with `lastArguments`. Add these tests to `Core/Tests/GitHubKitTests/GitHubClientTests.swift`:

```swift
private let sampleIssueSearchJSON = """
[
  {
    "number": 42,
    "title": "Login crashes on empty password",
    "url": "https://github.com/bsv-blockchain/teranode/issues/42",
    "state": "open",
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let sampleIssueViewJSON = """
{
  "number": 42,
  "title": "Login crashes on empty password",
  "url": "https://github.com/bsv-blockchain/teranode/issues/42",
  "state": "OPEN",
  "author": { "login": "alice" }
}
"""

private let repoViewMainJSON = """
{ "isFork": false, "parent": null, "defaultBranchRef": { "name": "main" } }
"""

@Test func searchIssuesParsesResultsAndAppendsIsIssue() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleIssueSearchJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchIssues(query: "assignee:@me is:open")

    #expect(hits.count == 1)
    #expect(hits[0].owner == "bsv-blockchain")
    #expect(hits[0].repo == "teranode")
    #expect(hits[0].number == 42)
    #expect(hits[0].authorLogin == "alice")
    #expect(hits[0].state == "open")
    #expect(hits[0].id == "bsv-blockchain/teranode/issues/42")
    #expect(hits[0].locator == IssueLocator(owner: "bsv-blockchain", repo: "teranode", number: 42))

    let args = await runner.lastArguments
    #expect(args == ["search", "issues", "assignee:@me", "is:open", "is:issue", "--json", "number,title,url,state,author,repository", "--limit", "100"])
}

@Test func searchIssuesDoesNotDuplicateIsIssue() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    _ = try await client.searchIssues(query: "assignee:@me is:issue")
    let args = await runner.lastArguments
    #expect(args == ["search", "issues", "assignee:@me", "is:issue", "--json", "number,title,url,state,author,repository", "--limit", "100"])
}

@Test func searchIssuesThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "auth required"))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    await #expect(throws: GitHubError.self) {
        try await client.searchIssues(query: "assignee:@me")
    }
}

@Test func fetchIssueBuildsWorkItemWithBranchAndBase() async throws {
    // First call: gh issue view → issue JSON. Second call: gh repo view → default base.
    let runner = RecordingRunner(results: [
        CommandResult(exitCode: 0, standardOutput: sampleIssueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewMainJSON, standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let item = try await client.fetchIssue(
        for: IssueLocator(owner: "bsv-blockchain", repo: "teranode", number: 42),
        origin: .discovered
    )

    #expect(item.prRef == nil)
    #expect(item.issueRef?.number == 42)
    #expect(item.issueRef?.authorLogin == "alice")
    #expect(item.repoKey == "github.com/bsv-blockchain/teranode")
    #expect(item.baseBranch == "main")
    #expect(item.headBranch == "issue-42-login-crashes-on-empty-password")
    #expect(item.prState == .open)
    #expect(item.origin == .discovered)
    #expect(item.category(myLogin: nil) == .issue)
}
```

> Note: confirm `RecordingRunner` exposes an array initializer `init(results:)`. If it only has `init(result:)`, add an `init(results: [CommandResult])` that returns them in order (mirror `StubRunner` in `AppModelTests.swift`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter searchIssuesParsesResultsAndAppendsIsIssue`
Expected: FAIL — `searchIssues` / `IssueHit` unresolved.

- [ ] **Step 3: Add `mapIssueState`, `IssueHit`, `searchIssues`, `fetchIssue`**

In `GitHubClient.swift`, add a decoder struct near the other private decode structs:

```swift
struct GHIssue: Decodable {
    struct Author: Decodable { let login: String }
    let number: Int
    let title: String
    let url: String
    let state: String
    let author: Author
}

private struct GHIssueSearchHit: Decodable {
    struct Author: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    let number: Int
    let title: String
    let url: String
    let state: String
    let author: Author
    let repository: Repository
}
```

Add the public `IssueHit` type (next to `DiscoveryHit`):

```swift
public struct IssueHit: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    public let state: String

    public var id: String { "\(owner)/\(repo)/issues/\(number)" }
    public var locator: IssueLocator { IssueLocator(owner: owner, repo: repo, number: number) }

    public init(owner: String, repo: String, number: Int, title: String, url: String, authorLogin: String, state: String) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.state = state
    }
}
```

Add to the `extension GitHubClient` that holds `searchPRs` (or a new extension):

```swift
extension GitHubClient {
    public static func mapIssueState(state: String) -> PRState {
        state.uppercased() == "CLOSED" ? .closed : .open
    }

    public func searchIssues(query: String) async throws -> [IssueHit] {
        let fields = "number,title,url,state,author,repository"
        var tokens = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if !tokens.contains("is:issue") {
            tokens.append("is:issue")
        }
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["search", "issues"] + tokens + ["--json", fields, "--limit", "100"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let raw: [GHIssueSearchHit]
        do {
            raw = try JSONDecoder().decode([GHIssueSearchHit].self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return raw.compactMap { row -> IssueHit? in
            let parts = row.repository.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return IssueHit(
                owner: parts[0], repo: parts[1], number: row.number, title: row.title,
                url: row.url, authorLogin: row.author.login, state: row.state
            )
        }
    }

    public func fetchIssue(for loc: IssueLocator, origin: ReviewOrigin = .added, now: Date = Date()) async throws -> WorkItem {
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["issue", "view", String(loc.number), "--repo", "\(loc.owner)/\(loc.repo)", "--json", "number,title,url,state,author"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let issue: GHIssue
        do {
            issue = try JSONDecoder().decode(GHIssue.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        guard let url = URL(string: issue.url) else {
            throw GitHubError.decodingFailed("invalid url: \(issue.url)")
        }
        let base = (try? await fetchDefaultBase(owner: loc.owner, repo: loc.repo)) ?? "main"
        return WorkItem(
            title: issue.title,
            repoKey: "github.com/\(loc.owner)/\(loc.repo)",
            baseBranch: base,
            headBranch: WorkItem.issueBranchName(number: issue.number, title: issue.title),
            issueRef: IssueRef(
                owner: loc.owner, repo: loc.repo, number: issue.number,
                url: url, authorLogin: issue.author.login
            ),
            prState: GitHubClient.mapIssueState(state: issue.state),
            origin: origin,
            addedAt: now
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter searchIssues` then
`swift test --package-path Core --filter fetchIssueBuildsWorkItemWithBranchAndBase`
Expected: PASS

- [ ] **Step 5: Run the full GitHubKit suite**

Run: `swift test --package-path Core --filter GitHubKitTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/GitHubKit/GitHubClient.swift Core/Tests/GitHubKitTests/GitHubClientTests.swift
git commit -m "feat(github): add searchIssues and fetchIssue" --no-verify
```

---

### Task 5: `ClaudeLaunchBuilder` issue command

**Files:**
- Modify: `Core/Sources/ClaudeSessionKit/ClaudeLaunchBuilder.swift`
- Test: `Core/Tests/ClaudeSessionKitTests/ClaudeLaunchBuilderTests.swift`

**Interfaces:**
- Consumes: `WorkItem.issueRef`, `WorkItem.issueNumber`, `WorkItem.displayNumber` (Task 1)
- Produces: launch behavior — issue items (no PR) emit `/start-issue <issueNumber>` as the fresh-session initial command; `sessionName` uses `#<displayNumber> <title>`.

- [ ] **Step 1: Write the failing test**

Add to `Core/Tests/ClaudeSessionKitTests/ClaudeLaunchBuilderTests.swift`:

```swift
private func sampleIssueItem() -> WorkItem {
    WorkItem(
        title: "Login crash",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crash",
        issueRef: IssueRef(
            owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!,
            authorLogin: "alice"
        ),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
}

@Test func launchBuilderIssueUsesStartIssueCommand() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleIssueItem(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        sessionID: "abc",
        resume: false
    )
    #expect(spec.arguments.contains("/start-issue 42"))
    #expect(!spec.arguments.contains { $0.hasPrefix("/review") })
    let nameIdx = spec.arguments.firstIndex(of: "--name")
    #expect(nameIdx != nil)
    if let nameIdx {
        #expect(spec.arguments[spec.arguments.index(after: nameIdx)] == "#42 Login crash")
    }
}

@Test func launchBuilderIssueResumeOmitsStartIssue() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleIssueItem(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        sessionID: "abc",
        resume: true
    )
    #expect(!spec.arguments.contains { $0.hasPrefix("/start-issue") })
    #expect(spec.arguments.contains("--resume"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter launchBuilderIssueUsesStartIssueCommand`
Expected: FAIL — issue item currently produces no `/start-issue` and `sessionName` returns the bare title (no `#42`, since old `sessionName` used `review.number` which is nil for issues).

- [ ] **Step 3: Modify `ClaudeLaunchBuilder.swift`**

Replace the fresh-session command block (the `else` branch that appends `--session-id`) so it picks the right command:

```swift
        if resume {
            args.append("--resume")
            args.append(sessionID)
        } else {
            args.append("--session-id")
            args.append(sessionID)
            if review.prRef != nil, let url = review.url {
                args.append("/review \(url.absoluteString)")
            } else if let issueNumber = review.issueNumber {
                args.append("/start-issue \(issueNumber)")
            }
        }
```

Replace `sessionName(for:)` to use `displayNumber`:

```swift
    static func sessionName(for review: WorkItem) -> String {
        if let number = review.displayNumber {
            return "#\(number) \(review.title)"
        }
        return review.title
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter launchBuilderIssue`
Expected: PASS (both new tests).

- [ ] **Step 5: Run the full ClaudeSessionKit launch suite (PR behavior unchanged)**

Run: `swift test --package-path Core --filter ClaudeLaunchBuilderTests`
Expected: PASS — the existing `/review` test still passes (PRs still emit `/review`).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/ClaudeSessionKit/ClaudeLaunchBuilder.swift Core/Tests/ClaudeSessionKitTests/ClaudeLaunchBuilderTests.swift
git commit -m "feat(claude): launch /start-issue for issue work items" --no-verify
```

---

### Task 6: `Settings` issue queries + collapse flag

**Files:**
- Modify: `Core/Sources/PRPilotModels/Settings.swift`
- Test: `Core/Tests/PRPilotModelsTests/ModelsTests.swift` (or wherever Settings decode is tested — search for `Settings(` in `PRPilotModelsTests`; if no Settings decode test exists, add the test to `ModelsTests.swift`).

**Interfaces:**
- Produces:
  - `Settings.issueQueries: [DiscoveryQuery]` (default `Settings.defaultIssueQueries == [DiscoveryQuery(text: "assignee:@me is:open")]`)
  - `Settings.issuesEnabled: Bool` (default `true`)
  - `Settings.issuesCollapsed: Bool` (default `false`)
  - memberwise init gains `issueQueries:`, `issuesEnabled:`, `issuesCollapsed:` with those defaults.

- [ ] **Step 1: Write the failing test**

Add to the Settings test file:

```swift
@Test func settingsDecodeWithoutIssueFieldsUsesDefaults() throws {
    // A pre-issue settings blob: has reviewRequestQueries/myPRQueries but no issue fields.
    let json = """
    {
      "managedRoot": "/tmp/PRPilot",
      "reviewRequestQueries": [{"text": "review-requested:@me is:open", "allowUnscoped": false}],
      "myPRQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "reviewRequestsEnabled": true,
      "myPRsEnabled": true,
      "pollIntervalSeconds": 120,
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.issuesEnabled == true)
    #expect(s.issuesCollapsed == false)
    #expect(s.issueQueries == [DiscoveryQuery(text: "assignee:@me is:open")])
}

@Test func settingsDefaultHasIssueQueries() {
    #expect(Settings.default.issueQueries == [DiscoveryQuery(text: "assignee:@me is:open")])
    #expect(Settings.default.issuesEnabled == true)
}
```

> If `diffMode`/`diffIgnoreWhitespace` decode requires different literals, copy the exact values from an existing Settings decode test in the file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter settingsDecodeWithoutIssueFieldsUsesDefaults`
Expected: FAIL — `issueQueries` / `issuesEnabled` / `issuesCollapsed` unresolved.

- [ ] **Step 3: Modify `Settings.swift`**

Add stored properties (after `myPRsEnabled`):

```swift
    public var issueQueries: [DiscoveryQuery]
    public var issuesEnabled: Bool
```

Add (after `reviewsCollapsed`):

```swift
    public var issuesCollapsed: Bool
```

Add a default queries static (next to `defaultMyPRQueries`):

```swift
    public static let defaultIssueQueries: [DiscoveryQuery] = [
        DiscoveryQuery(text: "assignee:@me is:open"),
    ]
```

In the memberwise `init`, add params (after `myPRsEnabled: Bool = true,`):

```swift
        issueQueries: [DiscoveryQuery] = Settings.defaultIssueQueries,
        issuesEnabled: Bool = true,
```

and (after `reviewsCollapsed: Bool = false,`):

```swift
        issuesCollapsed: Bool = false,
```

with assignments in the init body:

```swift
        self.issueQueries = issueQueries
        self.issuesEnabled = issuesEnabled
        self.issuesCollapsed = issuesCollapsed
```

In `init(from decoder:)`, add (alongside `reviewsCollapsed`/`myWorkCollapsed` decode):

```swift
        issuesCollapsed = try c.decodeIfPresent(Bool.self, forKey: .issuesCollapsed) ?? false
        issueQueries = try c.decodeIfPresent([DiscoveryQuery].self, forKey: .issueQueries) ?? Settings.defaultIssueQueries
        issuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .issuesEnabled) ?? true
```

> `Settings` has no explicit `CodingKeys` enum (it relies on synthesized keys plus a `LegacyKeys` helper). Adding the three stored properties auto-extends the synthesized `CodingKeys`, so `forKey: .issuesCollapsed` etc. resolve. Verify the file compiles; if a manual `CodingKeys` was added later, add the three cases there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter settingsDecodeWithoutIssueFieldsUsesDefaults` then
`swift test --package-path Core --filter settingsDefaultHasIssueQueries`
Expected: PASS

- [ ] **Step 5: Run the full models suite**

Run: `swift test --package-path Core --filter PRPilotModelsTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PRPilotModels/Settings.swift Core/Tests/PRPilotModelsTests/
git commit -m "feat(settings): add issue discovery queries and collapse flag" --no-verify
```

---

### Task 7: `AppModel` issue discovery, auto-start, and add-by-URL

**Files:**
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Test: `Core/Tests/AppCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `GitHubClient.searchIssues`, `fetchIssue`, `mapIssueState` (Task 4); `IssueLocator` (Task 3); `Settings.issueQueries`/`issuesEnabled` (Task 6); existing `ensureClaudeSession`, `webPreloadHandler`, `prefetch`.
- Produces:
  - `AppModel.addIssue(urlString: String) async`
  - private `mergeDiscoveredIssues(_:)`, `issueKey(_:)`, `pruneStaleDiscoveredIssues(currentIssueIDs:)`, `issueAutoStart(_:)`
  - `discoverNow()` additionally queries issues and merges them.

- [ ] **Step 1: Write the failing tests**

Add to `Core/Tests/AppCoreTests/AppModelTests.swift`. These reuse the existing `StubRunner(results:)`, `StubWorktreeProvider`, etc.

```swift
private let issueViewJSON = """
{
  "number": 42,
  "title": "Login crash",
  "url": "https://github.com/bsv-blockchain/teranode/issues/42",
  "state": "OPEN",
  "author": { "login": "alice" }
}
"""
private let repoViewJSON = """
{ "isFork": false, "parent": null, "defaultBranchRef": { "name": "main" } }
"""

@Test @MainActor func addIssueFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    // fetchIssue → gh issue view, then gh repo view (fetchDefaultBase).
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: issueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewJSON, standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addIssue(urlString: "https://github.com/bsv-blockchain/teranode/issues/42")

    #expect(model.reviews.count == 1)
    let item = try #require(model.reviews.first)
    #expect(item.issueRef?.number == 42)
    #expect(item.prRef == nil)
    #expect(item.headBranch == "issue-42-login-crash")
    #expect(item.category(myLogin: nil) == .issue)
    #expect(model.selection == item.id)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addIssueSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addIssue(urlString: "https://github.com/o/r/pull/7")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter addIssueFetchesStoresAndSelects`
Expected: FAIL — `model.addIssue` does not exist.

- [ ] **Step 3: Add `addIssue` to `AppModel.swift`**

Add after `addPR(urlString:)`:

```swift
    public func addIssue(urlString: String) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let loc = try IssueLocator.parse(urlString)
            let item = try await client.fetchIssue(for: loc)
            try await store.upsertItem(item)
            reviews = await store.allItems()
            selection = item.id
            errorMessage = nil
            prefetch(for: item)
            webPreloadHandler?(item)
        } catch {
            errorMessage = String(describing: error)
        }
    }
```

- [ ] **Step 4: Add discovery merge + prune + auto-start helpers**

Add near `mergeDiscoveryHits` / `pruneStaleDiscoveredReviews`:

```swift
    private func issueKey(_ item: WorkItem) -> String? {
        guard let r = item.issueRef else { return nil }
        return "\(r.owner)/\(r.repo)/issues/\(r.number)"
    }

    private func issueAutoStart(_ item: WorkItem) {
        guard !item.disabled else { return }
        Task { await ensureClaudeSession(for: item) }
        webPreloadHandler?(item)
    }

    private func mergeDiscoveredIssues(_ hits: [IssueHit]) async {
        let existingByKey = Dictionary(
            reviews.compactMap { item in issueKey(item).map { ($0, item) } },
            uniquingKeysWith: { a, _ in a }
        )
        for hit in hits {
            if let existing = existingByKey[hit.id] {
                var updated = existing
                updated.title = hit.title
                updated.prState = GitHubClient.mapIssueState(state: hit.state)
                if existing.origin == .added { updated.origin = .both }
                try? await store.upsertItem(updated)
            } else {
                guard let fresh = try? await client.fetchIssue(for: hit.locator, origin: .discovered) else { continue }
                try? await store.upsertItem(fresh)
                issueAutoStart(fresh)
            }
        }
        reviews = await store.allItems()
    }

    private func pruneStaleDiscoveredIssues(currentIssueIDs: Set<String>) async {
        let staleIDs = reviews.compactMap { item -> String? in
            guard item.origin == .discovered, item.issueRef != nil else { return nil }
            guard item.prState == .closed else { return nil }
            guard let key = issueKey(item), !currentIssueIDs.contains(key) else { return nil }
            return item.id
        }
        for id in staleIDs {
            do { try await store.removeItem(id: id) } catch { continue }
        }
        if !staleIDs.isEmpty {
            reviews = await store.allItems()
        }
    }
```

- [ ] **Step 5: Wire issue discovery into `discoverNow()`**

In `discoverNow()`, after the existing PR `for group in groups` loop and BEFORE `discoveryWarnings = warnings`, insert:

```swift
        var issueHitsByID: [String: IssueHit] = [:]
        var anyIssueQuerySucceeded = false
        if settings.issuesEnabled {
            for query in settings.issueQueries {
                let text = query.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                guard query.isScoped || query.allowUnscoped else {
                    warnings.append("Skipped \"\(text)\" — not scoped to you, an org, or a repo. Add a qualifier (author:/org:/repo:/…) or enable \"run anyway\".")
                    continue
                }
                guard let results = try? await client.searchIssues(query: text) else { continue }
                anyIssueQuerySucceeded = true
                if results.count >= 100 {
                    warnings.append("\"\(text)\" returned 100+ results (too broad) — refine it. Those results were not added.")
                    continue
                }
                for hit in results {
                    issueHitsByID[hit.id] = hit
                }
            }
        }
```

Then, after the existing `await mergeDiscoveryHits(...)` and the PR prune block, append:

```swift
        await mergeDiscoveredIssues(Array(issueHitsByID.values))
        if anyIssueQuerySucceeded {
            await pruneStaleDiscoveredIssues(currentIssueIDs: Set(issueHitsByID.keys))
        }
```

> Keep the single `discoveryWarnings = warnings` assignment — it now also contains issue-query warnings since they append to the same `warnings` array.

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `swift test --package-path Core --filter addIssue`
Expected: PASS (both tests).

- [ ] **Step 7: Run the full AppCore suite (discovery/regression)**

Run: `swift test --package-path Core --filter AppCoreTests`
Expected: PASS (existing PR discovery/add tests unaffected).

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): discover assigned issues and add issue by URL" --no-verify
```

---

### Task 8: Sidebar "Issues" section + DetailView default pane

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/DetailView.swift`

**Interfaces:**
- Consumes: `sidebarSections(...).issues` (Task 2); `Settings.issuesCollapsed` (Task 6); `WorkItem.issueRef` (Task 1).
- Produces: a third sidebar `Section` titled "Issues"; corrected `defaultPaneForSelection`.

- [ ] **Step 1: Add the Issues section to `ContentView.swift`**

In `body`, after the "Review Requests" `Section { … }`, add:

```swift
                Section(isExpanded: issuesExpandedBinding()) {
                    sectionBody(sections.issues)
                } header: {
                    SidebarSectionHeader(title: "Issues", count: sections.issues.count, kind: .issues)
                }
```

Add the binding helper (next to `reviewsExpandedBinding`):

```swift
    private func issuesExpandedBinding() -> Binding<Bool> {
        Binding(
            get: { !model.settings.issuesCollapsed },
            set: { expanded in
                var updated = model.settings
                updated.issuesCollapsed = !expanded
                Task { await model.updateSettings(updated) }
            }
        )
    }
```

Add `.issues` to the `SidebarSectionKind` enum:

```swift
private enum SidebarSectionKind {
    case myWork
    case reviewRequests
    case issues
}
```

Add a `SectionStyle.issues` factory (mirror the existing two; teal/green hue to distinguish):

```swift
    static func issues(_ scheme: ColorScheme) -> SectionStyle {
        scheme == .dark
            ? SectionStyle(
                band: Color(red: 0.149, green: 0.247, blue: 0.243),
                border: Color(red: 0.298, green: 0.686, blue: 0.620),
                text: Color(red: 0.486, green: 0.831, blue: 0.769)
            )
            : SectionStyle(
                band: Color(red: 0.890, green: 0.965, blue: 0.953),
                border: Color(red: 0.118, green: 0.533, blue: 0.451),
                text: Color(red: 0.063, green: 0.396, blue: 0.333)
            )
    }
```

In `SidebarSectionHeader.style`, add the case:

```swift
        case .issues: return .issues(colorScheme)
```

- [ ] **Step 2: Fix `defaultPaneForSelection` in `DetailView.swift`**

Replace the method with:

```swift
    // PRs and issues have a web page → show GitHub. Freeform tasks have no page → Claude.
    private func defaultPaneForSelection() {
        if review.disabled {
            pane = .github
            return
        }
        if review.prRef == nil && review.issueRef == nil {
            pane = .claude
        } else {
            pane = .github
        }
    }
```

- [ ] **Step 3: Build the app to verify it compiles**

Run: `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual smoke check**

Launch the app (or `xcodebuild` run). Confirm: a third "Issues" header appears in the sidebar; selecting an issue opens the GitHub pane showing the issue URL; selecting a freeform task still opens the Claude pane.

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift App/DetailView.swift
git commit -m "feat(sidebar): add Issues section and default issues to GitHub pane" --no-verify
```

---

### Task 9: Add Issue by URL sheet + menu + Settings query editor

**Files:**
- Create: `App/AddIssueSheet.swift`
- Modify: `App/ContentView.swift`
- Modify: `App/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.addIssue` (Task 7); `Settings.issueQueries`/`issuesEnabled` (Task 6); existing `querySection` helper.
- Produces: `AddIssueSheet` view; an "Add Issue by URL…" menu item; an "Issues" query section in Discovery settings.

- [ ] **Step 1: Create `App/AddIssueSheet.swift`**

```swift
import SwiftUI
import AppCore

struct AddIssueSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var urlString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an issue")
                .font(.headline)
            TextField("https://github.com/owner/repo/issues/123", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
            HStack {
                if model.isAdding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    Task {
                        await model.addIssue(urlString: urlString)
                        if model.errorMessage == nil {
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.isEmpty || model.isAdding)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 2: Wire the menu + sheet into `ContentView.swift`**

Add a state var next to `showingAdd`:

```swift
    @State private var showingAddIssue = false
```

In the "Add" `Menu`, add a button after "Add PR by URL…":

```swift
                        Button { showingAddIssue = true } label: { Label("Add Issue by URL…", systemImage: "exclamationmark.circle") }
```

Add a sheet modifier next to the existing `.sheet(isPresented: $showingAdd)`:

```swift
            .sheet(isPresented: $showingAddIssue) {
                AddIssueSheet(model: model, isPresented: $showingAddIssue)
            }
```

- [ ] **Step 3: Add the Issues query section to `SettingsView.swift`**

In `DiscoverySettingsTab`, add state vars (next to `myPRRows`/`myPRsEnabled`):

```swift
    @State private var issueRows: [QueryRow] = []
    @State private var issuesEnabled = true
```

Add the section after the "My PRs" section call:

```swift
            querySection(title: "Issues", rows: $issueRows, enabled: $issuesEnabled)
```

In `.onAppear`, add:

```swift
            issueRows = model.settings.issueQueries.map { QueryRow(text: $0.text, allowUnscoped: $0.allowUnscoped) }
            issuesEnabled = model.settings.issuesEnabled
```

Add the change observers (next to the other `.onChange`):

```swift
        .onChange(of: issueRows) { _, _ in commit() }
        .onChange(of: issuesEnabled) { _, _ in commit() }
```

In `commit()`, add:

```swift
        updated.issueQueries = issueRows
            .map { DiscoveryQuery(text: $0.text.trimmingCharacters(in: .whitespaces), allowUnscoped: $0.allowUnscoped) }
            .filter { !$0.text.isEmpty }
        updated.issuesEnabled = issuesEnabled
```

- [ ] **Step 4: Build the app to verify it compiles**

Run: `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual smoke check**

Launch the app. Confirm: the "+" menu shows "Add Issue by URL…"; entering a real assigned issue URL adds it, clones (first time), creates the `issue-<n>-<slug>` worktree, shows the issue in the GitHub pane, and starts a Claude `/start-issue` session. Settings ▸ Discovery shows an editable "Issues" query group defaulting to `assignee:@me is:open`.

- [ ] **Step 6: Commit**

```bash
git add App/AddIssueSheet.swift App/ContentView.swift App/SettingsView.swift
git commit -m "feat(ui): add issue-by-URL sheet and issue discovery settings" --no-verify
```

---

## Final verification

- [ ] **Run the entire Core test suite**

Run: `swift test --package-path Core`
Expected: PASS, 0 failures (report the exact pass/fail counts).

- [ ] **Build the full app**

Run: `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **End-to-end (manual, requires a real assigned issue):** With `issuesEnabled` on and a real `assignee:@me is:open` issue, let discovery poll. Confirm the repo is cloned, an `issue-<n>-<slug>` worktree is created, the GitHub pane shows the issue, and a real `claude` session starts on `/start-issue <n>`.

---

## Self-Review notes (verification of plan vs spec)

- Spec §1 Model → Task 1. §2 Discovery (searchIssues/Settings/AppModel) → Tasks 4, 6, 7. §3 Auto-start → Task 7 (`issueAutoStart`). §4 Worktree (no new code) → confirmed, no task. §5 Claude launch → Task 5. §6 UI (sidebar/DetailView/Add Issue/Settings) → Tasks 2, 8, 9. Error handling → reused (Tasks 7). Testing → each Core task is TDD; UI tasks build + manual.
- Issue open/closed stored in `prState` → Task 4 `mapIssueState`, Task 7 merge.
- `number` stays PR-only → Task 1 accessors (verified in `issueItemAccessors` test).
- Naming consistency: `issueRef`, `issueNumber`, `displayNumber`, `issueBranchName`, `searchIssues`, `fetchIssue`, `mapIssueState`, `IssueHit.id`, `issueKey`, `mergeDiscoveredIssues`, `pruneStaleDiscoveredIssues`, `issueAutoStart`, `addIssue`, `issueQueries`, `issuesEnabled`, `issuesCollapsed` used consistently across tasks.
