# Remote Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an iPhone or iPad on the tailnet monitor the PR Pilot queue and clear common blockers, without running Claude Code on the device.

**Architecture:** A new `GatewayKit` package module runs an embedded Hummingbird HTTP server inside the Mac app. It projects `AppModel` into a flat `GatewaySnapshot`, pushes that snapshot over Server-Sent Events whenever it changes, and accepts commands on one `POST` route. A vendored Preact client, served from the app bundle and fronted by `tailscale serve`, renders the queue grouped by what needs attention.

**Tech Stack:** Swift 6, swift-testing, Hummingbird 2, SwiftNIO, Preact + htm (vendored ES modules), Server-Sent Events, Tailscale 1.98.9.

**Spec:** `docs/superpowers/specs/2026-09-16-remote-gateway-design.md`

## Global Constraints

- Target is macOS 14. `Core/Package.swift` declares `platforms: [.macOS(.v14)]`.
- Swift tools version 6.0. `SWIFT_VERSION` is `6.0` in `project.yml`.
- Tests use swift-testing: `import Testing`, `@Test`, `#expect`. Never XCTest.
- `GatewayKit` depends on `PRPilotModels` and Hummingbird only. It must never depend on `AppCore` or `AgentKit`. `AgentKit` links SwiftTerm, and the gateway renders no terminal.
- Go style rules in `~/.claude/CLAUDE.md` do not apply. This is Swift.
- No comments unless the code is genuinely non-obvious, matching the surrounding codebase, which comments the *why* and never the *what*.
- The listener binds to `127.0.0.1` only. Never `0.0.0.0`. Never `tailscale funnel`.
- Authentication is a bearer token. A tailnet identity header is never trusted on its own, because any local process can forge it.
- There is no git command in the gateway. `GatewayCommand` has no case for `push`, `rebase`, `continueRebase`, or `abortRebase`.
- The client fetches nothing from a CDN. Every dependency is vendored into the app bundle.
- Default gateway port is 8776.
- Run the full test suite with `swift test --package-path Core`. Run it after every task.

---

### Task 1: Package scaffold and Hummingbird dependency

Hummingbird 2's API surface is the one external unknown in this plan. This task exists to prove it compiles and serves a request before any real code is built on it. If the API has drifted, that is discovered here, not in Task 7.

**Files:**
- Modify: `Core/Package.swift`
- Create: `Core/Sources/GatewayKit/GatewayVersion.swift`
- Test: `Core/Tests/GatewayKitTests/HummingbirdSmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the `GatewayKit` module and `GatewayKitTests` target. `public enum GatewayVersion { public static let current = 1 }`.

- [ ] **Step 1: Add the dependency, target, product and test target to `Core/Package.swift`**

In `dependencies`, after the SwiftTerm line:

```swift
.package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
```

In `products`, after the `AppCore` library:

```swift
.library(name: "GatewayKit", targets: ["GatewayKit"]),
```

In `targets`, after the `AgentKit` target:

```swift
.target(
    name: "GatewayKit",
    dependencies: [
        "PRPilotModels",
        .product(name: "Hummingbird", package: "hummingbird"),
    ]
),
```

In `targets`, after the `AgentKitTests` test target:

```swift
.testTarget(
    name: "GatewayKitTests",
    dependencies: [
        "GatewayKit",
        "PRPilotModels",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
    ]
),
```

- [ ] **Step 2: Create the module's first file so the target compiles**

`Core/Sources/GatewayKit/GatewayVersion.swift`:

```swift
public enum GatewayVersion {
    /// Bumped when the wire format changes in a way an installed client cannot read.
    public static let current = 1
}
```

- [ ] **Step 3: Write the smoke test**

`Core/Tests/GatewayKitTests/HummingbirdSmokeTests.swift`:

```swift
import Testing
import Hummingbird
import HummingbirdTesting
@testable import GatewayKit

@Test func hummingbirdServesAPlainRoute() async throws {
    let router = Router()
    router.get("/ping") { _, _ in "pong" }
    let app = Application(router: router)

    try await app.test(.router) { client in
        try await client.execute(uri: "/ping", method: .get) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "pong")
        }
    }
}

@Test func gatewayVersionIsOne() {
    #expect(GatewayVersion.current == 1)
}
```

- [ ] **Step 4: Resolve dependencies and run the test**

Run: `swift test --package-path Core --filter GatewayKitTests`

Expected: both tests PASS.

If the Hummingbird API has drifted and this fails to compile, STOP. Report the exact compiler error and the resolved Hummingbird version from `Core/Package.resolved`. Do not guess at replacement API. Every later task's route and middleware code assumes the shapes used here.

- [ ] **Step 5: Run the full suite**

Run: `swift test --package-path Core`

Expected: PASS. Record any pre-existing failures. `drainReleasesAnIdleSessionAtTheCapAndStartsTheNext` and `terminateReleasesThePtyWhileTheSessionObjectLives` are known to fail intermittently on a clean tree; re-run once to confirm a failure is that flake and not new.

- [ ] **Step 6: Commit**

```bash
git add Core/Package.swift Core/Package.resolved Core/Sources/GatewayKit Core/Tests/GatewayKitTests
git commit --no-verify -m "feat(gateway): add GatewayKit module with Hummingbird"
```

---

### Task 2: Wire types

**Files:**
- Create: `Core/Sources/GatewayKit/GatewaySnapshot.swift`
- Test: `Core/Tests/GatewayKitTests/GatewaySnapshotTests.swift`

**Interfaces:**
- Consumes: `GatewayVersion` from Task 1.
- Produces: `GatewaySnapshot`, `GatewayGroup`, `GatewayGroupKind`, `GatewayItem`, `GatewayItemKind`, `GatewayAgent`, `GatewayBadge`, `GatewayBadgeTone`. All `Codable`, `Sendable`, `Equatable`. Task 3 returns `GatewayGroupKind`. Task 9 builds `GatewayItem`. Tasks 11 and 12 render these field names in JavaScript, so the names are a contract.

- [ ] **Step 1: Write the failing test**

`Core/Tests/GatewayKitTests/GatewaySnapshotTests.swift`:

```swift
import Testing
import Foundation
@testable import GatewayKit

private func sampleItem() -> GatewayItem {
    GatewayItem(
        id: "bsv-blockchain/teranode#4788",
        kind: .pr,
        owner: "bsv-blockchain",
        repo: "teranode",
        number: 4788,
        url: "https://github.com/bsv-blockchain/teranode/pull/4788",
        title: "UTXO store: drop the legacy index path",
        author: "bob",
        headBranch: "feat/utxo-legacy-drop",
        baseBranch: "main",
        attentionReason: "Agent hit its usage limit",
        agent: GatewayAgent(kind: "codex", status: "limited", verdict: "Two concerns.", elapsedSeconds: 1080, usedPercent: 100),
        badges: [GatewayBadge(text: "✗ CI", tone: .red, help: "CI is failing")],
        issueStatus: nil,
        label: nil,
        isDisabled: false,
        ahead: 0,
        behind: 12,
        localChanges: 2,
        lastActivityAt: Date(timeIntervalSince1970: 1_789_000_000),
        primaryCommand: nil
    )
}

@Test func snapshotSurvivesACodableRoundTrip() throws {
    let snapshot = GatewaySnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_789_000_100),
        gatewayVersion: GatewayVersion.current,
        appVersion: "0.9.1",
        login: "ordishs",
        groups: [GatewayGroup(kind: .needsYou, items: [sampleItem()])],
        warnings: ["discovery query failed"]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(GatewaySnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func groupKindsEncodeAsTheNamesTheClientReads() throws {
    let encoded = try JSONEncoder().encode(
        [GatewayGroupKind.needsYou, .running, .queued, .idle]
    )
    #expect(String(decoding: encoded, as: UTF8.self) == #"["needsYou","running","queued","idle"]"#)
}

@Test func badgeTonesEncodeAsTheNamesTheClientReads() throws {
    let encoded = try JSONEncoder().encode(
        [GatewayBadgeTone.green, .orange, .red, .blue, .grey]
    )
    #expect(String(decoding: encoded, as: UTF8.self) == #"["green","orange","red","blue","grey"]"#)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Core --filter GatewaySnapshotTests`
Expected: FAIL to compile — `cannot find 'GatewayItem' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/GatewayKit/GatewaySnapshot.swift`:

```swift
import Foundation

public enum GatewayGroupKind: String, Codable, Sendable, Equatable, CaseIterable {
    case needsYou
    case running
    case queued
    case idle
}

public enum GatewayItemKind: String, Codable, Sendable, Equatable {
    case pr
    case issue
    case task
}

public enum GatewayBadgeTone: String, Codable, Sendable, Equatable {
    case green
    case orange
    case red
    case blue
    case grey
}

public struct GatewayBadge: Codable, Sendable, Equatable {
    public var text: String
    public var tone: GatewayBadgeTone
    /// The same sentence the Mac badge shows on hover. A five-letter chip cannot say
    /// which actor it is talking about, and the phone has no hover to fall back on.
    public var help: String

    public init(text: String, tone: GatewayBadgeTone, help: String) {
        self.text = text
        self.tone = tone
        self.help = help
    }
}

public struct GatewayAgent: Codable, Sendable, Equatable {
    public var kind: String
    public var status: String
    public var verdict: String?
    public var elapsedSeconds: Int?
    public var usedPercent: Int?

    public init(
        kind: String,
        status: String,
        verdict: String? = nil,
        elapsedSeconds: Int? = nil,
        usedPercent: Int? = nil
    ) {
        self.kind = kind
        self.status = status
        self.verdict = verdict
        self.elapsedSeconds = elapsedSeconds
        self.usedPercent = usedPercent
    }
}

public struct GatewayItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: GatewayItemKind
    public var owner: String?
    public var repo: String?
    public var number: Int?
    public var url: String?
    public var title: String
    public var author: String?
    public var headBranch: String?
    public var baseBranch: String
    public var attentionReason: String?
    public var agent: GatewayAgent?
    public var badges: [GatewayBadge]
    public var issueStatus: String?
    public var label: String?
    public var isDisabled: Bool
    public var ahead: Int
    public var behind: Int
    public var localChanges: Int
    public var lastActivityAt: Date?
    public var primaryCommand: GatewayCommand?

    public init(
        id: String,
        kind: GatewayItemKind,
        owner: String?,
        repo: String?,
        number: Int?,
        url: String?,
        title: String,
        author: String?,
        headBranch: String?,
        baseBranch: String,
        attentionReason: String?,
        agent: GatewayAgent?,
        badges: [GatewayBadge],
        issueStatus: String?,
        label: String?,
        isDisabled: Bool,
        ahead: Int,
        behind: Int,
        localChanges: Int,
        lastActivityAt: Date?,
        primaryCommand: GatewayCommand?
    ) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.attentionReason = attentionReason
        self.agent = agent
        self.badges = badges
        self.issueStatus = issueStatus
        self.label = label
        self.isDisabled = isDisabled
        self.ahead = ahead
        self.behind = behind
        self.localChanges = localChanges
        self.lastActivityAt = lastActivityAt
        self.primaryCommand = primaryCommand
    }
}

public struct GatewayGroup: Codable, Sendable, Equatable {
    public var kind: GatewayGroupKind
    public var items: [GatewayItem]

    public init(kind: GatewayGroupKind, items: [GatewayItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct GatewaySnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var gatewayVersion: Int
    public var appVersion: String
    public var login: String?
    public var groups: [GatewayGroup]
    public var warnings: [String]

    public init(
        generatedAt: Date,
        gatewayVersion: Int = GatewayVersion.current,
        appVersion: String,
        login: String?,
        groups: [GatewayGroup],
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.gatewayVersion = gatewayVersion
        self.appVersion = appVersion
        self.login = login
        self.groups = groups
        self.warnings = warnings
    }
}
```

`GatewayItem.primaryCommand` refers to `GatewayCommand`, which Task 4 defines. This task will not compile until Task 4 lands. Do Task 4 next, then return here. If you would rather keep each task green on its own, implement Task 4 before Task 2; the two are a single compile unit either way.

- [ ] **Step 4: Note the ordering and move to Task 4**

Do not run the suite yet. Steps 5 and 6 below run after Task 4's implementation exists.

- [ ] **Step 5: Run the tests (after Task 4)**

Run: `swift test --package-path Core --filter GatewaySnapshotTests`
Expected: PASS, all three tests.

- [ ] **Step 6: Commit (after Task 4)**

```bash
git add Core/Sources/GatewayKit/GatewaySnapshot.swift Core/Tests/GatewayKitTests/GatewaySnapshotTests.swift
git commit --no-verify -m "feat(gateway): add the snapshot wire types"
```

---

### Task 3: Grouping rule

This is the rule the whole list layout depends on. It is pure and total, so it gets the most test cases in the plan.

**Files:**
- Create: `Core/Sources/GatewayKit/GatewayGrouping.swift`
- Test: `Core/Tests/GatewayKitTests/GatewayGroupingTests.swift`

**Interfaces:**
- Consumes: `GatewayGroupKind` from Task 2, `GatewayCommand` from Task 4.
- Produces: `GatewayItemFacts` and `GatewayGrouping.classify(_:)` returning `GatewayClassification`. Task 9 calls `classify` and puts its output on the `GatewayItem`.

- [ ] **Step 1: Write the failing test**

`Core/Tests/GatewayKitTests/GatewayGroupingTests.swift`:

```swift
import Testing
@testable import GatewayKit

private func facts(
    id: String = "owner/repo#1",
    isDisabled: Bool = false,
    limitMessage: String? = nil,
    awaitsMyResponse: Bool = false,
    hasVerdict: Bool = false,
    hasUnseenAuthorUpdate: Bool = false,
    sessionIsLive: Bool = false,
    isQueued: Bool = false
) -> GatewayItemFacts {
    GatewayItemFacts(
        id: id,
        isDisabled: isDisabled,
        limitMessage: limitMessage,
        awaitsMyResponse: awaitsMyResponse,
        hasVerdict: hasVerdict,
        hasUnseenAuthorUpdate: hasUnseenAuthorUpdate,
        sessionIsLive: sessionIsLive,
        isQueued: isQueued
    )
}

@Test func aLimitedAgentNeedsYouAndOffersToClearTheLimit() {
    let result = GatewayGrouping.classify(facts(limitMessage: "5-hour limit reached"))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Agent hit its usage limit")
    #expect(result.primaryCommand == .clearAgentLimit(id: "owner/repo#1"))
}

@Test func anAgentAwaitingAnAnswerNeedsYouAndOffersToClearTheWait() {
    let result = GatewayGrouping.classify(facts(awaitsMyResponse: true))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Agent is waiting for you")
    #expect(result.primaryCommand == .clearWaiting(id: "owner/repo#1"))
}

@Test func aFinishedReviewNeedsYouButOffersNoCommand() {
    let result = GatewayGrouping.classify(facts(hasVerdict: true))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Agent finished its review")
    #expect(result.primaryCommand == nil)
}

@Test func anUnseenAuthorPushNeedsYouAndOffersToMarkItSeen() {
    let result = GatewayGrouping.classify(facts(hasUnseenAuthorUpdate: true))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Author pushed new commits")
    #expect(result.primaryCommand == .markAuthorUpdateSeen(id: "owner/repo#1"))
}

@Test func aLimitOutranksEveryOtherReason() {
    let result = GatewayGrouping.classify(
        facts(
            limitMessage: "spend limit",
            awaitsMyResponse: true,
            hasVerdict: true,
            hasUnseenAuthorUpdate: true
        )
    )

    #expect(result.reason == "Agent hit its usage limit")
}

@Test func awaitingAnAnswerOutranksAVerdictAndAnAuthorPush() {
    let result = GatewayGrouping.classify(
        facts(awaitsMyResponse: true, hasVerdict: true, hasUnseenAuthorUpdate: true)
    )

    #expect(result.reason == "Agent is waiting for you")
}

@Test func aVerdictOutranksAnAuthorPush() {
    let result = GatewayGrouping.classify(facts(hasVerdict: true, hasUnseenAuthorUpdate: true))

    #expect(result.reason == "Agent finished its review")
}

@Test func aLiveSessionWithNothingOutstandingIsRunning() {
    let result = GatewayGrouping.classify(facts(sessionIsLive: true))

    #expect(result.group == .running)
    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}

@Test func aQueuedItemIsQueued() {
    let result = GatewayGrouping.classify(facts(isQueued: true))

    #expect(result.group == .queued)
    #expect(result.reason == nil)
}

@Test func aLiveSessionOutranksTheQueue() {
    let result = GatewayGrouping.classify(facts(sessionIsLive: true, isQueued: true))

    #expect(result.group == .running)
}

@Test func anItemWithNothingHappeningIsIdle() {
    let result = GatewayGrouping.classify(facts())

    #expect(result.group == .idle)
    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}

@Test func aDisabledItemIsAlwaysIdleWhateverElseIsTrue() {
    let result = GatewayGrouping.classify(
        facts(
            isDisabled: true,
            limitMessage: "5-hour limit reached",
            awaitsMyResponse: true,
            hasVerdict: true,
            hasUnseenAuthorUpdate: true,
            sessionIsLive: true,
            isQueued: true
        )
    )

    #expect(result.group == .idle)
    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Core --filter GatewayGroupingTests`
Expected: FAIL to compile — `cannot find 'GatewayItemFacts' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/GatewayKit/GatewayGrouping.swift`:

```swift
/// Flat view of one work item's state, built by `AppCore`.
///
/// `AgentStatus` lives in `AgentKit`, which links SwiftTerm. A gateway that renders no
/// terminal must not drag a terminal emulator in behind it, so the caller flattens the
/// status into booleans at the boundary.
public struct GatewayItemFacts: Sendable, Equatable {
    public var id: String
    public var isDisabled: Bool
    public var limitMessage: String?
    public var awaitsMyResponse: Bool
    public var hasVerdict: Bool
    public var hasUnseenAuthorUpdate: Bool
    public var sessionIsLive: Bool
    public var isQueued: Bool

    public init(
        id: String,
        isDisabled: Bool,
        limitMessage: String?,
        awaitsMyResponse: Bool,
        hasVerdict: Bool,
        hasUnseenAuthorUpdate: Bool,
        sessionIsLive: Bool,
        isQueued: Bool
    ) {
        self.id = id
        self.isDisabled = isDisabled
        self.limitMessage = limitMessage
        self.awaitsMyResponse = awaitsMyResponse
        self.hasVerdict = hasVerdict
        self.hasUnseenAuthorUpdate = hasUnseenAuthorUpdate
        self.sessionIsLive = sessionIsLive
        self.isQueued = isQueued
    }
}

public struct GatewayClassification: Sendable, Equatable {
    public var group: GatewayGroupKind
    public var reason: String?
    public var primaryCommand: GatewayCommand?
}

public enum GatewayGrouping {
    /// Total, pure, first match wins. A disabled item has no session to nudge and no
    /// review to read, so it never reaches the attention branches.
    public static func classify(_ facts: GatewayItemFacts) -> GatewayClassification {
        if facts.isDisabled {
            return GatewayClassification(group: .idle, reason: nil, primaryCommand: nil)
        }
        if facts.limitMessage != nil {
            return GatewayClassification(
                group: .needsYou,
                reason: "Agent hit its usage limit",
                primaryCommand: .clearAgentLimit(id: facts.id)
            )
        }
        if facts.awaitsMyResponse {
            return GatewayClassification(
                group: .needsYou,
                reason: "Agent is waiting for you",
                primaryCommand: .clearWaiting(id: facts.id)
            )
        }
        if facts.hasVerdict {
            return GatewayClassification(
                group: .needsYou,
                reason: "Agent finished its review",
                primaryCommand: nil
            )
        }
        if facts.hasUnseenAuthorUpdate {
            return GatewayClassification(
                group: .needsYou,
                reason: "Author pushed new commits",
                primaryCommand: .markAuthorUpdateSeen(id: facts.id)
            )
        }
        if facts.sessionIsLive {
            return GatewayClassification(group: .running, reason: nil, primaryCommand: nil)
        }
        if facts.isQueued {
            return GatewayClassification(group: .queued, reason: nil, primaryCommand: nil)
        }
        return GatewayClassification(group: .idle, reason: nil, primaryCommand: nil)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter GatewayGroupingTests`
Expected: PASS, all twelve tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/GatewayKit/GatewayGrouping.swift Core/Tests/GatewayKitTests/GatewayGroupingTests.swift
git commit --no-verify -m "feat(gateway): add the attention grouping rule"
```

---

### Task 4: Commands, result and backend protocol

**Files:**
- Create: `Core/Sources/GatewayKit/GatewayCommand.swift`
- Create: `Core/Sources/GatewayKit/GatewayBackend.swift`
- Test: `Core/Tests/GatewayKitTests/GatewayCommandTests.swift`

**Interfaces:**
- Consumes: `GatewaySnapshot` from Task 2.
- Produces: `GatewayCommand`, `GatewayCommandEnvelope`, `GatewayCommandResult`, `GatewayBackend`. Task 7 decodes an envelope and calls `backend.perform`. Task 9 implements `GatewayBackend` on `AppModel`. Task 12 encodes these shapes in JavaScript.

- [ ] **Step 1: Write the failing test**

`Core/Tests/GatewayKitTests/GatewayCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import GatewayKit

private func decode(_ json: String) throws -> GatewayCommand {
    try JSONDecoder().decode(GatewayCommand.self, from: Data(json.utf8))
}

@Test func refreshAllDecodesFromItsTypeAlone() throws {
    #expect(try decode(#"{"type":"refreshAll"}"#) == .refreshAll)
}

@Test func commandsCarryingAnIdDecodeThatId() throws {
    #expect(try decode(#"{"type":"refreshItem","id":"a#1"}"#) == .refreshItem(id: "a#1"))
    #expect(try decode(#"{"type":"clearWaiting","id":"a#1"}"#) == .clearWaiting(id: "a#1"))
    #expect(try decode(#"{"type":"clearSession","id":"a#1"}"#) == .clearSession(id: "a#1"))
    #expect(try decode(#"{"type":"clearAgentLimit","id":"a#1"}"#) == .clearAgentLimit(id: "a#1"))
    #expect(try decode(#"{"type":"handOver","id":"a#1"}"#) == .handOver(id: "a#1"))
    #expect(try decode(#"{"type":"removeItem","id":"a#1"}"#) == .removeItem(id: "a#1"))
    #expect(try decode(#"{"type":"markAuthorUpdateSeen","id":"a#1"}"#) == .markAuthorUpdateSeen(id: "a#1"))
}

@Test func startSessionCarriesItsFreshFlag() throws {
    #expect(
        try decode(#"{"type":"startSession","id":"a#1","forceFresh":true}"#)
            == .startSession(id: "a#1", forceFresh: true)
    )
}

@Test func setDisabledCarriesItsFlag() throws {
    #expect(
        try decode(#"{"type":"setDisabled","id":"a#1","disabled":true}"#)
            == .setDisabled(id: "a#1", disabled: true)
    )
}

@Test func setLabelAcceptsAValueAndAClear() throws {
    #expect(try decode(#"{"type":"setLabel","id":"a#1","label":"perf"}"#) == .setLabel(id: "a#1", label: "perf"))
    #expect(try decode(#"{"type":"setLabel","id":"a#1"}"#) == .setLabel(id: "a#1", label: nil))
}

@Test func addCommandsCarryTheirUrl() throws {
    let url = "https://github.com/o/r/pull/1"
    #expect(try decode(#"{"type":"addPR","url":"\#(url)"}"#) == .addPR(url: url))
    #expect(try decode(#"{"type":"addIssue","url":"\#(url)"}"#) == .addIssue(url: url))
}

@Test func everyCommandSurvivesARoundTrip() throws {
    let all: [GatewayCommand] = [
        .refreshAll,
        .refreshItem(id: "a#1"),
        .markAuthorUpdateSeen(id: "a#1"),
        .clearWaiting(id: "a#1"),
        .setPane(id: "a#1", pane: "github"),
        .startSession(id: "a#1", forceFresh: false),
        .clearSession(id: "a#1"),
        .clearAgentLimit(id: "a#1"),
        .handOver(id: "a#1"),
        .addPR(url: "https://example.com/1"),
        .addIssue(url: "https://example.com/2"),
        .setIssueStatus(id: "a#1", status: "done"),
        .setLabel(id: "a#1", label: "perf"),
        .setDisabled(id: "a#1", disabled: true),
        .removeItem(id: "a#1"),
    ]

    for command in all {
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(GatewayCommand.self, from: data) == command)
    }
}

@Test func anUnknownTypeIsRejected() {
    #expect(throws: DecodingError.self) {
        try decode(#"{"type":"push","id":"a#1"}"#)
    }
}

@Test func theEnvelopeCarriesACommandIdAlongsideTheCommand() throws {
    let envelope = try JSONDecoder().decode(
        GatewayCommandEnvelope.self,
        from: Data(#"{"commandID":"c-1","command":{"type":"refreshAll"}}"#.utf8)
    )

    #expect(envelope.commandID == "c-1")
    #expect(envelope.command == .refreshAll)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Core --filter GatewayCommandTests`
Expected: FAIL to compile — `cannot find 'GatewayCommand' in scope`.

- [ ] **Step 3: Write `GatewayCommand.swift`**

There is deliberately no case for `push`, `rebase`, `continueRebase` or `abortRebase`. A request cannot reach a git action because no case encodes one.

```swift
import Foundation

public enum GatewayCommand: Codable, Sendable, Equatable {
    case refreshAll
    case refreshItem(id: String)
    case markAuthorUpdateSeen(id: String)
    case clearWaiting(id: String)
    case setPane(id: String, pane: String)
    case startSession(id: String, forceFresh: Bool)
    case clearSession(id: String)
    case clearAgentLimit(id: String)
    case handOver(id: String)
    case addPR(url: String)
    case addIssue(url: String)
    case setIssueStatus(id: String, status: String?)
    case setLabel(id: String, label: String?)
    case setDisabled(id: String, disabled: Bool)
    case removeItem(id: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, url, pane, status, label, disabled, forceFresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        func id() throws -> String { try c.decode(String.self, forKey: .id) }

        switch type {
        case "refreshAll": self = .refreshAll
        case "refreshItem": self = .refreshItem(id: try id())
        case "markAuthorUpdateSeen": self = .markAuthorUpdateSeen(id: try id())
        case "clearWaiting": self = .clearWaiting(id: try id())
        case "setPane":
            self = .setPane(id: try id(), pane: try c.decode(String.self, forKey: .pane))
        case "startSession":
            self = .startSession(
                id: try id(),
                forceFresh: try c.decodeIfPresent(Bool.self, forKey: .forceFresh) ?? false
            )
        case "clearSession": self = .clearSession(id: try id())
        case "clearAgentLimit": self = .clearAgentLimit(id: try id())
        case "handOver": self = .handOver(id: try id())
        case "addPR": self = .addPR(url: try c.decode(String.self, forKey: .url))
        case "addIssue": self = .addIssue(url: try c.decode(String.self, forKey: .url))
        case "setIssueStatus":
            self = .setIssueStatus(
                id: try id(),
                status: try c.decodeIfPresent(String.self, forKey: .status)
            )
        case "setLabel":
            self = .setLabel(
                id: try id(),
                label: try c.decodeIfPresent(String.self, forKey: .label)
            )
        case "setDisabled":
            self = .setDisabled(
                id: try id(),
                disabled: try c.decode(Bool.self, forKey: .disabled)
            )
        case "removeItem": self = .removeItem(id: try id())
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown command type \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .refreshAll:
            try c.encode("refreshAll", forKey: .type)
        case .refreshItem(let id):
            try c.encode("refreshItem", forKey: .type); try c.encode(id, forKey: .id)
        case .markAuthorUpdateSeen(let id):
            try c.encode("markAuthorUpdateSeen", forKey: .type); try c.encode(id, forKey: .id)
        case .clearWaiting(let id):
            try c.encode("clearWaiting", forKey: .type); try c.encode(id, forKey: .id)
        case .setPane(let id, let pane):
            try c.encode("setPane", forKey: .type); try c.encode(id, forKey: .id)
            try c.encode(pane, forKey: .pane)
        case .startSession(let id, let forceFresh):
            try c.encode("startSession", forKey: .type); try c.encode(id, forKey: .id)
            try c.encode(forceFresh, forKey: .forceFresh)
        case .clearSession(let id):
            try c.encode("clearSession", forKey: .type); try c.encode(id, forKey: .id)
        case .clearAgentLimit(let id):
            try c.encode("clearAgentLimit", forKey: .type); try c.encode(id, forKey: .id)
        case .handOver(let id):
            try c.encode("handOver", forKey: .type); try c.encode(id, forKey: .id)
        case .addPR(let url):
            try c.encode("addPR", forKey: .type); try c.encode(url, forKey: .url)
        case .addIssue(let url):
            try c.encode("addIssue", forKey: .type); try c.encode(url, forKey: .url)
        case .setIssueStatus(let id, let status):
            try c.encode("setIssueStatus", forKey: .type); try c.encode(id, forKey: .id)
            try c.encodeIfPresent(status, forKey: .status)
        case .setLabel(let id, let label):
            try c.encode("setLabel", forKey: .type); try c.encode(id, forKey: .id)
            try c.encodeIfPresent(label, forKey: .label)
        case .setDisabled(let id, let disabled):
            try c.encode("setDisabled", forKey: .type); try c.encode(id, forKey: .id)
            try c.encode(disabled, forKey: .disabled)
        case .removeItem(let id):
            try c.encode("removeItem", forKey: .type); try c.encode(id, forKey: .id)
        }
    }
}

public struct GatewayCommandEnvelope: Codable, Sendable, Equatable {
    public var commandID: String
    public var command: GatewayCommand

    public init(commandID: String, command: GatewayCommand) {
        self.commandID = commandID
        self.command = command
    }
}

public struct GatewayCommandResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case accepted
        case rejected
    }

    public var status: Status
    public var message: String?
    public var snapshot: GatewaySnapshot

    public init(status: Status, message: String? = nil, snapshot: GatewaySnapshot) {
        self.status = status
        self.message = message
        self.snapshot = snapshot
    }
}
```

- [ ] **Step 4: Write `GatewayBackend.swift`**

```swift
/// What the gateway needs from the app, and nothing more.
///
/// `AppCore` conforms `AppModel` to this. The dependency flows `AppCore -> GatewayKit`,
/// so every route in this module is testable against a fake with no `AppModel`, no `gh`
/// and no git.
@MainActor
public protocol GatewayBackend: AnyObject, Sendable {
    func snapshot() -> GatewaySnapshot
    func perform(_ command: GatewayCommand) async -> GatewayCommandResult
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Core --filter GatewayKitTests`
Expected: PASS. Task 2's `GatewaySnapshotTests` now compile and pass too.

- [ ] **Step 6: Commit both tasks**

```bash
git add Core/Sources/GatewayKit Core/Tests/GatewayKitTests
git commit --no-verify -m "feat(gateway): add snapshot wire types, commands and the backend protocol"
```

---

### Task 5: Idempotency ledger

A phone on a tunnel retries. Without this, one retried `addPR` adds the PR twice and one retried `startSession` spawns a second agent process.

**Files:**
- Create: `Core/Sources/GatewayKit/CommandLedger.swift`
- Test: `Core/Tests/GatewayKitTests/CommandLedgerTests.swift`

**Interfaces:**
- Consumes: `GatewayCommandResult` from Task 4.
- Produces: `actor CommandLedger` with `func result(for: String) -> GatewayCommandResult?` and `func record(_ result: GatewayCommandResult, for: String)`. Task 7 consults it before calling the backend.

- [ ] **Step 1: Write the failing test**

`Core/Tests/GatewayKitTests/CommandLedgerTests.swift`:

```swift
import Testing
import Foundation
@testable import GatewayKit

private func result(_ message: String) -> GatewayCommandResult {
    GatewayCommandResult(
        status: .accepted,
        message: message,
        snapshot: GatewaySnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "test",
            login: nil,
            groups: [],
            warnings: []
        )
    )
}

@Test func anUnknownCommandIdHasNoRecordedResult() async {
    let ledger = CommandLedger(capacity: 4)
    #expect(await ledger.result(for: "never-seen") == nil)
}

@Test func aRecordedResultComesBackForTheSameCommandId() async {
    let ledger = CommandLedger(capacity: 4)
    await ledger.record(result("first"), for: "c-1")

    #expect(await ledger.result(for: "c-1")?.message == "first")
}

@Test func theOldestEntryIsEvictedOnceCapacityIsReached() async {
    let ledger = CommandLedger(capacity: 2)
    await ledger.record(result("one"), for: "c-1")
    await ledger.record(result("two"), for: "c-2")
    await ledger.record(result("three"), for: "c-3")

    #expect(await ledger.result(for: "c-1") == nil)
    #expect(await ledger.result(for: "c-2")?.message == "two")
    #expect(await ledger.result(for: "c-3")?.message == "three")
}

@Test func rerecordingTheSameIdReplacesTheResultWithoutGrowing() async {
    let ledger = CommandLedger(capacity: 2)
    await ledger.record(result("one"), for: "c-1")
    await ledger.record(result("one-again"), for: "c-1")
    await ledger.record(result("two"), for: "c-2")

    #expect(await ledger.result(for: "c-1")?.message == "one-again")
    #expect(await ledger.result(for: "c-2")?.message == "two")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Core --filter CommandLedgerTests`
Expected: FAIL to compile — `cannot find 'CommandLedger' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/GatewayKit/CommandLedger.swift`:

```swift
/// Remembers recent command results so a retry over a dropped tunnel does not run the
/// command twice.
public actor CommandLedger {
    private let capacity: Int
    private var order: [String] = []
    private var results: [String: GatewayCommandResult] = [:]

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public func result(for commandID: String) -> GatewayCommandResult? {
        results[commandID]
    }

    public func record(_ result: GatewayCommandResult, for commandID: String) {
        if results[commandID] == nil {
            order.append(commandID)
        }
        results[commandID] = result

        while order.count > capacity {
            let evicted = order.removeFirst()
            results.removeValue(forKey: evicted)
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter CommandLedgerTests`
Expected: PASS, all four tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/GatewayKit/CommandLedger.swift Core/Tests/GatewayKitTests/CommandLedgerTests.swift
git commit --no-verify -m "feat(gateway): make commands idempotent across tunnel retries"
```

---

### Task 6: Identity verification

Read the Authentication section of the spec before writing this. The short version: the listener is on loopback, so any local process can connect and any local process can forge a proxy header. A shared secret is the only thing a forged header cannot supply.

**Files:**
- Create: `Core/Sources/GatewayKit/IdentityVerifier.swift`
- Test: `Core/Tests/GatewayKitTests/IdentityVerifierTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `GatewayIdentity`, `IdentityVerifier`, `BearerTokenVerifier`, `TailnetHeaderVerifier`. Task 7 wraps a verifier in middleware.

- [ ] **Step 1: Write the failing test**

`Core/Tests/GatewayKitTests/IdentityVerifierTests.swift`:

```swift
import Testing
@testable import GatewayKit

@Test func theBearerVerifierAcceptsTheExactToken() {
    let verifier = BearerTokenVerifier(token: "s3cret")
    let identity = verifier.verify(headers: ["authorization": "Bearer s3cret"])

    #expect(identity != nil)
}

@Test func theBearerVerifierIsCaseInsensitiveOnTheSchemeButNotTheToken() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["authorization": "bearer s3cret"]) != nil)
    #expect(verifier.verify(headers: ["authorization": "Bearer S3CRET"]) == nil)
}

@Test func theBearerVerifierRejectsAWrongOrMissingToken() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["authorization": "Bearer wrong"]) == nil)
    #expect(verifier.verify(headers: ["authorization": "s3cret"]) == nil)
    #expect(verifier.verify(headers: [:]) == nil)
}

@Test func theBearerVerifierReportsTheTailnetUserWhenTheProxySuppliedOne() {
    let verifier = BearerTokenVerifier(token: "s3cret")
    let identity = verifier.verify(
        headers: ["authorization": "Bearer s3cret", "tailscale-user-login": "me@example.com"]
    )

    #expect(identity?.login == "me@example.com")
}

@Test func theBearerVerifierStillAcceptsWhenNoTailnetUserIsSupplied() {
    let verifier = BearerTokenVerifier(token: "s3cret")
    let identity = verifier.verify(headers: ["authorization": "Bearer s3cret"])

    #expect(identity != nil)
    #expect(identity?.login == nil)
}

@Test func theHeaderVerifierAcceptsAnAllowlistedLogin() {
    let verifier = TailnetHeaderVerifier(headerName: "tailscale-user-login", allowlist: ["me@example.com"])

    #expect(verifier.verify(headers: ["tailscale-user-login": "me@example.com"])?.login == "me@example.com")
}

@Test func theHeaderVerifierRejectsALoginThatIsNotAllowlisted() {
    let verifier = TailnetHeaderVerifier(headerName: "tailscale-user-login", allowlist: ["me@example.com"])

    #expect(verifier.verify(headers: ["tailscale-user-login": "someone@else.com"]) == nil)
    #expect(verifier.verify(headers: [:]) == nil)
}

@Test func anEmptyAllowlistRejectsEveryLogin() {
    let verifier = TailnetHeaderVerifier(headerName: "tailscale-user-login", allowlist: [])

    #expect(verifier.verify(headers: ["tailscale-user-login": "me@example.com"]) == nil)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Core --filter IdentityVerifierTests`
Expected: FAIL to compile — `cannot find 'BearerTokenVerifier' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/GatewayKit/IdentityVerifier.swift`:

```swift
import Foundation

public struct GatewayIdentity: Sendable, Equatable {
    /// The tailnet login, when the proxy supplied one. Display and audit only — it is a
    /// request header, so a local process can set it to anything.
    public var login: String?

    public init(login: String?) {
        self.login = login
    }
}

/// Header keys are lowercased by the caller before they reach a verifier.
public protocol IdentityVerifier: Sendable {
    func verify(headers: [String: String]) -> GatewayIdentity?
}

/// The default. A shared secret is the one thing a forged header cannot supply, and the
/// listener sits on loopback where any local process can set any header it likes.
public struct BearerTokenVerifier: IdentityVerifier {
    private let token: String
    private let tailnetHeaderName: String

    public init(token: String, tailnetHeaderName: String = "tailscale-user-login") {
        self.token = token
        self.tailnetHeaderName = tailnetHeaderName
    }

    public func verify(headers: [String: String]) -> GatewayIdentity? {
        guard let raw = headers["authorization"] else { return nil }

        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        guard constantTimeEquals(String(parts[1]), token) else { return nil }

        return GatewayIdentity(login: headers[tailnetHeaderName])
    }

    /// Compares over the full length of both strings so a timing difference cannot leak
    /// how many leading characters of a guess were right.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        var difference = lhs.count ^ rhs.count
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? Int(lhs[index]) : 0
            let r = index < rhs.count ? Int(rhs[index]) : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}

/// Only safe where the transport guarantees the header came from the proxy. Never the
/// default on a loopback port. Kept for a future move to a Unix socket that only
/// `tailscale serve` can open.
public struct TailnetHeaderVerifier: IdentityVerifier {
    private let headerName: String
    private let allowlist: Set<String>

    public init(headerName: String, allowlist: Set<String>) {
        self.headerName = headerName
        self.allowlist = allowlist
    }

    public func verify(headers: [String: String]) -> GatewayIdentity? {
        guard let login = headers[headerName], allowlist.contains(login) else { return nil }
        return GatewayIdentity(login: login)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter IdentityVerifierTests`
Expected: PASS, all eight tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/GatewayKit/IdentityVerifier.swift Core/Tests/GatewayKitTests/IdentityVerifierTests.swift
git commit --no-verify -m "feat(gateway): authenticate requests with a bearer token"
```

---

### Task 7: HTTP routes

**Files:**
- Create: `Core/Sources/GatewayKit/GatewayRouter.swift`
- Test: `Core/Tests/GatewayKitTests/GatewayRouterTests.swift`
- Test: `Core/Tests/GatewayKitTests/FakeGatewayBackend.swift`

**Interfaces:**
- Consumes: everything from Tasks 2 through 6.
- Produces: `GatewayRouter.make(backend:verifier:ledger:) -> Router<BasicRequestContext>`. Task 8 adds the SSE route to the same router. Task 10 builds an `Application` from it.

- [ ] **Step 1: Write the fake backend the router tests drive**

`Core/Tests/GatewayKitTests/FakeGatewayBackend.swift`:

```swift
import Foundation
@testable import GatewayKit

@MainActor
final class FakeGatewayBackend: GatewayBackend {
    private(set) var received: [GatewayCommand] = []
    var nextStatus: GatewayCommandResult.Status = .accepted
    var nextMessage: String?
    var login: String? = "ordishs"
    var groups: [GatewayGroup] = []

    func snapshot() -> GatewaySnapshot {
        GatewaySnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_789_000_000),
            appVersion: "test",
            login: login,
            groups: groups,
            warnings: []
        )
    }

    func perform(_ command: GatewayCommand) async -> GatewayCommandResult {
        received.append(command)
        return GatewayCommandResult(status: nextStatus, message: nextMessage, snapshot: snapshot())
    }
}
```

- [ ] **Step 2: Write the failing router test**

`Core/Tests/GatewayKitTests/GatewayRouterTests.swift`:

```swift
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import GatewayKit

private let token = "test-token"

@MainActor
private func makeApp(_ backend: FakeGatewayBackend) -> some ApplicationProtocol {
    Application(
        router: GatewayRouter.make(
            backend: backend,
            verifier: BearerTokenVerifier(token: token),
            ledger: CommandLedger(capacity: 8),
            appVersion: "test"
        )
    )
}

private var auth: [(String, String)] { [("authorization", "Bearer \(token)")] }

private func headers(_ pairs: [(String, String)]) -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in pairs {
        fields[HTTPField.Name(name)!] = value
    }
    return fields
}

@Test func healthNeedsNoTokenAndReportsTheVersion() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/health", method: .get) { response in
            #expect(response.status == .ok)
            let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
            #expect(json?["appVersion"] as? String == "test")
            #expect(json?["gatewayVersion"] as? Int == GatewayVersion.current)
        }
    }
}

@Test func theSnapshotRouteRejectsARequestWithNoToken() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/snapshot", method: .get) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func theSnapshotRouteRejectsAWrongToken() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/snapshot",
            method: .get,
            headers: headers([("authorization", "Bearer wrong")])
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func theSnapshotRouteReturnsTheBackendSnapshot() async throws {
    let backend = await FakeGatewayBackend()
    await MainActor.run { backend.login = "ordishs" }
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/snapshot", method: .get, headers: headers(auth)) { response in
            #expect(response.status == .ok)
            let snapshot = try JSONDecoder().decode(GatewaySnapshot.self, from: Data(buffer: response.body))
            #expect(snapshot.login == "ordishs")
            #expect(snapshot.appVersion == "test")
        }
    }
}

@Test func aCommandReachesTheBackendAndReturnsItsResult() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"refreshAll"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            headers: headers(auth),
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .ok)
            let result = try JSONDecoder().decode(GatewayCommandResult.self, from: Data(buffer: response.body))
            #expect(result.status == .accepted)
        }
    }

    #expect(await backend.received == [.refreshAll])
}

@Test func aRepeatedCommandIdDoesNotReachTheBackendASecondTime() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"refreshAll"}}"#

    try await app.test(.router) { client in
        for _ in 0..<3 {
            try await client.execute(
                uri: "/api/command",
                method: .post,
                headers: headers(auth),
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    #expect(await backend.received.count == 1)
}

@Test func aCommandWithNoTokenIsRejectedAndNeverReachesTheBackend() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"refreshAll"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }

    #expect(await backend.received.isEmpty)
}

@Test func aGitCommandCannotBeDecodedSoItIsRejectedAsBadRequest() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"push","id":"a#1"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            headers: headers(auth),
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .badRequest)
        }
    }

    #expect(await backend.received.isEmpty)
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --package-path Core --filter GatewayRouterTests`
Expected: FAIL to compile — `cannot find 'GatewayRouter' in scope`.

- [ ] **Step 4: Write the implementation**

`Core/Sources/GatewayKit/GatewayRouter.swift`:

```swift
import Foundation
import Hummingbird
import HTTPTypes

struct GatewayAuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    let verifier: any IdentityVerifier

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var lowered: [String: String] = [:]
        for field in request.headers {
            lowered[field.name.canonicalName.lowercased()] = field.value
        }

        guard verifier.verify(headers: lowered) != nil else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }
}

public enum GatewayRouter {
    public static func make(
        backend: any GatewayBackend,
        verifier: any IdentityVerifier,
        ledger: CommandLedger,
        appVersion: String,
        broadcaster: SnapshotBroadcaster? = nil
    ) -> Router<BasicRequestContext> {
        let router = Router()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()

        // Health carries no state and no secret. It exists to tell you the tunnel is up
        // before you have pasted a token in.
        router.get("/api/health") { _, _ -> Response in
            let payload: [String: Any] = [
                "gatewayVersion": GatewayVersion.current,
                "appVersion": appVersion,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        let guarded = router.group("/api").add(middleware: GatewayAuthMiddleware(verifier: verifier))

        guarded.get("/snapshot") { _, _ -> Response in
            let snapshot = await MainActor.run { backend.snapshot() }
            return try json(encoder.encode(snapshot))
        }

        guarded.post("/command") { request, context -> Response in
            let body = try await request.body.collect(upTo: 64 * 1024)
            let envelope: GatewayCommandEnvelope
            do {
                envelope = try decoder.decode(GatewayCommandEnvelope.self, from: Data(buffer: body))
            } catch {
                throw HTTPError(.badRequest, message: "\(error)")
            }

            if let cached = await ledger.result(for: envelope.commandID) {
                return try json(encoder.encode(cached))
            }

            let result = await backend.perform(envelope.command)
            await ledger.record(result, for: envelope.commandID)
            broadcaster?.poke()
            return try json(encoder.encode(result))
        }

        return router
    }

    private static func json(_ data: Data) throws -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
```

`SnapshotBroadcaster` and its `poke()` arrive in Task 8. Until then the parameter defaults to `nil` and the call is a no-op, so this task compiles and its tests pass on their own. Do not remove the parameter; Task 8 needs it so a command pushes its result to every other connected client immediately rather than up to a second later.

If the Hummingbird middleware or routing API in your resolved version differs from the shapes above, STOP and report the compiler error rather than improvising. Task 1 pinned the version precisely so this does not become guesswork.

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Core --filter GatewayRouterTests`
Expected: PASS, all eight tests.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/GatewayKit/GatewayRouter.swift Core/Tests/GatewayKitTests/GatewayRouterTests.swift Core/Tests/GatewayKitTests/FakeGatewayBackend.swift
git commit --no-verify -m "feat(gateway): add health, snapshot and command routes"
```

---

### Task 8: SSE stream and coalescing poller

**Files:**
- Create: `Core/Sources/GatewayKit/SnapshotBroadcaster.swift`
- Modify: `Core/Sources/GatewayKit/GatewayRouter.swift`
- Test: `Core/Tests/GatewayKitTests/SnapshotBroadcasterTests.swift`

**Interfaces:**
- Consumes: `GatewaySnapshot`, `GatewayBackend`.
- Produces: `SnapshotBroadcaster` with `subscribe() -> AsyncStream<GatewaySnapshot>`, `poke()`, `var subscriberCount: Int`, and `var isPolling: Bool`. Task 10 owns one instance.

- [ ] **Step 1: Write the failing test**

`Core/Tests/GatewayKitTests/SnapshotBroadcasterTests.swift`:

```swift
import Testing
import Foundation
@testable import GatewayKit

@MainActor
private func backendReturning(_ login: String?) -> FakeGatewayBackend {
    let backend = FakeGatewayBackend()
    backend.login = login
    return backend
}

@Test func theFirstEventASubscriberReceivesIsTheCurrentSnapshot() async throws {
    let backend = await backendReturning("ordishs")
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    let stream = await broadcaster.subscribe()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()

    #expect(first?.login == "ordishs")
    await broadcaster.shutdown()
}

@Test func anUnchangedSnapshotProducesNoFurtherEvent() async throws {
    let backend = await backendReturning("ordishs")
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    let stream = await broadcaster.subscribe()
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    let second = try await withTimeout(milliseconds: 200) { await iterator.next() }
    #expect(second == nil, "an unchanged snapshot must not be re-sent")

    await broadcaster.shutdown()
}

@Test func aChangedSnapshotProducesAnEvent() async throws {
    let backend = await backendReturning("ordishs")
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    let stream = await broadcaster.subscribe()
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    await MainActor.run { backend.login = "someone-else" }

    let second = try await withTimeout(milliseconds: 2000) { await iterator.next() }
    #expect(second??.login == "someone-else")

    await broadcaster.shutdown()
}

@Test func thePollerStopsAfterTheLastSubscriberGoesAway() async throws {
    let backend = await backendReturning("ordishs")
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    do {
        let stream = await broadcaster.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await broadcaster.isPolling)
    }

    try await Task.sleep(for: .milliseconds(300))
    #expect(await broadcaster.subscriberCount == 0)
    #expect(await broadcaster.isPolling == false)
}

/// Returns nil when the operation did not finish in time, so a test can assert that
/// nothing arrived without hanging the suite.
private func withTimeout<T: Sendable>(
    milliseconds: Int,
    _ operation: @escaping @Sendable () async -> T
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return nil
        }
        let first = try await group.next()
        group.cancelAll()
        return first ?? nil
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Core --filter SnapshotBroadcasterTests`
Expected: FAIL to compile — `cannot find 'SnapshotBroadcaster' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/GatewayKit/SnapshotBroadcaster.swift`:

```swift
import Foundation

/// Watches the backend and pushes a snapshot to every subscriber when it changes.
///
/// `@Observable` tracking is one-shot and a missed re-registration stalls a long-lived
/// stream silently. A poller cannot miss an update, and it needs no change to `AppModel`.
/// The cost is up to one interval of latency and one wake-up per interval while a client
/// is connected. The poller runs only while somebody is listening.
public actor SnapshotBroadcaster {
    private let backend: any GatewayBackend
    private let interval: Duration
    private var continuations: [UUID: AsyncStream<GatewaySnapshot>.Continuation] = [:]
    private var lastHash: Int?
    private var pollTask: Task<Void, Never>?

    public init(backend: any GatewayBackend, interval: Duration = .seconds(1)) {
        self.backend = backend
        self.interval = interval
    }

    public var subscriberCount: Int { continuations.count }
    public var isPolling: Bool { pollTask != nil }

    public func subscribe() -> AsyncStream<GatewaySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GatewaySnapshot>.makeStream()
        continuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }

        let current = MainActor.assumeIsolated { backend.snapshot() }
        lastHash = fingerprint(of: current)
        continuation.yield(current)

        startPollingIfNeeded()
        return stream
    }

    /// Called right after a command runs, so every other client sees the effect at once
    /// instead of waiting out the interval.
    public nonisolated func poke() {
        Task { await self.tick() }
    }

    public func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func unsubscribe(_ id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            lastHash = nil
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard !continuations.isEmpty else { return }

        let snapshot = await MainActor.run { backend.snapshot() }
        let hash = fingerprint(of: snapshot)
        guard hash != lastHash else { return }

        lastHash = hash
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    /// `generatedAt` changes on every read, so hashing the whole snapshot would report a
    /// change every tick. The fingerprint covers everything the client renders and nothing
    /// that is merely a timestamp of the read itself.
    private func fingerprint(of snapshot: GatewaySnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.login)
        hasher.combine(snapshot.appVersion)
        hasher.combine(snapshot.warnings)
        for group in snapshot.groups {
            hasher.combine(group.kind)
            for item in group.items {
                hasher.combine(item)
            }
        }
        return hasher.finalize()
    }
}
```

`fingerprint` calls `hasher.combine(item)`, so `GatewayItem` must be `Hashable`. Add `Hashable` to the conformance lists of `GatewayItem`, `GatewayAgent`, `GatewayBadge`, `GatewayBadgeTone`, `GatewayItemKind`, `GatewayGroupKind` and `GatewayCommand` in `Core/Sources/GatewayKit/GatewaySnapshot.swift` and `Core/Sources/GatewayKit/GatewayCommand.swift`. `GatewayCommand` has a custom `Codable` implementation but a synthesized `Hashable` works because every associated value is already `Hashable`.

- [ ] **Step 4: Add the SSE route to `GatewayRouter.make`**

Insert after the `/snapshot` route, before the `/command` route:

```swift
guarded.get("/events") { _, _ -> Response in
    guard let broadcaster else { throw HTTPError(.serviceUnavailable) }
    let stream = await broadcaster.subscribe()

    let body = ResponseBody { writer in
        for await snapshot in stream {
            let data = try encoder.encode(snapshot)
            var frame = ByteBuffer()
            frame.writeString("data: ")
            frame.writeBytes(data)
            frame.writeString("\n\n")
            try await writer.write(frame)
        }
        try await writer.finish(nil)
    }

    return Response(
        status: .ok,
        headers: [
            .contentType: "text/event-stream",
            .cacheControl: "no-cache",
            .connection: "keep-alive",
        ],
        body: body
    )
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Core --filter GatewayKitTests`
Expected: PASS. The four broadcaster tests plus every earlier `GatewayKitTests` test.

These tests are timing-sensitive by nature. If one fails, re-run once before investigating. If it fails twice, it is real.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path Core`
Expected: PASS, apart from the two known flakes named in Task 1.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/GatewayKit Core/Tests/GatewayKitTests
git commit --no-verify -m "feat(gateway): push snapshots over server-sent events"
```

---

### Task 9: Conform `AppModel` to `GatewayBackend`

**Files:**
- Modify: `Core/Package.swift` (add `GatewayKit` to the `AppCore` target and to `AppCoreTests`)
- Modify: `Core/Sources/AppCore/AppModel.swift:1699` and `:1737` (visibility only)
- Create: `Core/Sources/AppCore/GatewayProjection.swift`
- Test: `Core/Tests/AppCoreTests/GatewayProjectionTests.swift`

**Interfaces:**
- Consumes: `GatewayBackend`, `GatewayItemFacts`, `GatewayGrouping`, and every wire type.
- Produces: `extension AppModel: GatewayBackend`. Task 10 passes an `AppModel` where a `GatewayBackend` is wanted.

- [ ] **Step 1: Add `GatewayKit` to the `AppCore` target in `Core/Package.swift`**

Change the `AppCore` target's dependency list to:

```swift
.target(
    name: "AppCore",
    dependencies: ["PRPilotModels", "ReviewStore", "GitHubKit", "CommandSupport", "WorktreeKit", "DiffKit", "AgentKit", "GatewayKit"]
),
```

And add `"GatewayKit"` to the `AppCoreTests` dependency list.

- [ ] **Step 2: Promote the two refresh methods to `public`**

`Core/Sources/AppCore/AppModel.swift:1699`: change `func refreshWorktreeCleanliness(for id: String) async {` to `public func refreshWorktreeCleanliness(for id: String) async {`.

`Core/Sources/AppCore/AppModel.swift:1737`: change `func refreshReviewState(for id: String, now: Date = Date()) async {` to `public func refreshReviewState(for id: String, now: Date = Date()) async {`.

- [ ] **Step 3: Write the failing test**

`Core/Tests/AppCoreTests/GatewayProjectionTests.swift`:

```swift
import Testing
import Foundation
import PRPilotModels
import GatewayKit
@testable import AppCore

private func prItem(
    id: String = "bsv-blockchain/teranode#4788",
    title: String = "UTXO store: drop the legacy index path",
    disabled: Bool = false,
    limitMessage: String? = nil,
    label: String? = nil
) -> WorkItem {
    var item = WorkItem(
        id: id,
        title: title,
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "feat/utxo-legacy-drop",
        prRef: PRRef(
            owner: "bsv-blockchain",
            repo: "teranode",
            number: 4788,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/4788")!,
            authorLogin: "bob"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_789_000_000),
        disabled: disabled,
        label: label
    )
    item.agentLimitMessage = limitMessage
    return item
}

@Test func aPullRequestProjectsItsIdentityOntoTheWireItem() {
    let projected = GatewayProjection.item(
        from: prItem(),
        facts: GatewayItemFacts(
            id: "bsv-blockchain/teranode#4788",
            isDisabled: false,
            limitMessage: nil,
            awaitsMyResponse: false,
            hasVerdict: false,
            hasUnseenAuthorUpdate: false,
            sessionIsLive: false,
            isQueued: false
        ),
        agent: nil,
        badges: [],
        issueStatus: nil,
        ahead: 0,
        behind: 12,
        localChanges: 2
    )

    #expect(projected.kind == .pr)
    #expect(projected.owner == "bsv-blockchain")
    #expect(projected.repo == "teranode")
    #expect(projected.number == 4788)
    #expect(projected.author == "bob")
    #expect(projected.baseBranch == "main")
    #expect(projected.headBranch == "feat/utxo-legacy-drop")
    #expect(projected.behind == 12)
    #expect(projected.localChanges == 2)
}

@Test func aLimitedItemCarriesItsReasonAndPrimaryCommandFromTheGroupingRule() {
    let projected = GatewayProjection.item(
        from: prItem(limitMessage: "5-hour limit reached"),
        facts: GatewayItemFacts(
            id: "bsv-blockchain/teranode#4788",
            isDisabled: false,
            limitMessage: "5-hour limit reached",
            awaitsMyResponse: false,
            hasVerdict: false,
            hasUnseenAuthorUpdate: false,
            sessionIsLive: false,
            isQueued: false
        ),
        agent: nil,
        badges: [],
        issueStatus: nil,
        ahead: 0,
        behind: 0,
        localChanges: 0
    )

    #expect(projected.attentionReason == "Agent hit its usage limit")
    #expect(projected.primaryCommand == .clearAgentLimit(id: "bsv-blockchain/teranode#4788"))
}

@Test func aFreeformTaskProjectsAsATaskWithNoNumber() {
    let task = WorkItem(
        id: "local/scratch",
        title: "Spike the gateway",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_789_000_000)
    )

    let projected = GatewayProjection.item(
        from: task,
        facts: GatewayItemFacts(
            id: "local/scratch",
            isDisabled: false,
            limitMessage: nil,
            awaitsMyResponse: false,
            hasVerdict: false,
            hasUnseenAuthorUpdate: false,
            sessionIsLive: false,
            isQueued: false
        ),
        agent: nil,
        badges: [],
        issueStatus: nil,
        ahead: 0,
        behind: 0,
        localChanges: 0
    )

    #expect(projected.kind == .task)
    #expect(projected.number == nil)
    #expect(projected.url == nil)
}

@Test func groupsAreOrderedNeedsYouRunningQueuedIdleAndEmptyOnesAreDropped() {
    let needy = prItem(id: "a#1", title: "needy", limitMessage: "limit")
    let plain = prItem(id: "a#2", title: "plain")

    let groups = GatewayProjection.groups(
        items: [plain, needy],
        facts: [
            "a#1": GatewayItemFacts(id: "a#1", isDisabled: false, limitMessage: "limit", awaitsMyResponse: false, hasVerdict: false, hasUnseenAuthorUpdate: false, sessionIsLive: false, isQueued: false),
            "a#2": GatewayItemFacts(id: "a#2", isDisabled: false, limitMessage: nil, awaitsMyResponse: false, hasVerdict: false, hasUnseenAuthorUpdate: false, sessionIsLive: false, isQueued: false),
        ],
        decorate: { _ in
            GatewayProjection.Decoration(agent: nil, badges: [], issueStatus: nil, ahead: 0, behind: 0, localChanges: 0)
        }
    )

    #expect(groups.map(\.kind) == [.needsYou, .idle])
    #expect(groups[0].items.map(\.title) == ["needy"])
    #expect(groups[1].items.map(\.title) == ["plain"])
}

@Test func removeIsRefusedWhileTheWorktreeHasLocalChanges() {
    #expect(GatewayProjection.removalRefusal(localChanges: 2) != nil)
    #expect(GatewayProjection.removalRefusal(localChanges: 0) == nil)
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `swift test --package-path Core --filter GatewayProjectionTests`
Expected: FAIL to compile — `cannot find 'GatewayProjection' in scope`.

- [ ] **Step 5: Write `Core/Sources/AppCore/GatewayProjection.swift`**

```swift
import Foundation
import PRPilotModels
import AgentKit
import GatewayKit

public enum GatewayProjection {
    public struct Decoration: Sendable {
        public var agent: GatewayAgent?
        public var badges: [GatewayBadge]
        public var issueStatus: String?
        public var ahead: Int
        public var behind: Int
        public var localChanges: Int

        public init(
            agent: GatewayAgent?,
            badges: [GatewayBadge],
            issueStatus: String?,
            ahead: Int,
            behind: Int,
            localChanges: Int
        ) {
            self.agent = agent
            self.badges = badges
            self.issueStatus = issueStatus
            self.ahead = ahead
            self.behind = behind
            self.localChanges = localChanges
        }
    }

    public static func item(
        from work: WorkItem,
        facts: GatewayItemFacts,
        agent: GatewayAgent?,
        badges: [GatewayBadge],
        issueStatus: String?,
        ahead: Int,
        behind: Int,
        localChanges: Int
    ) -> GatewayItem {
        let classification = GatewayGrouping.classify(facts)
        let kind: GatewayItemKind
        let owner: String?
        let repo: String?
        let number: Int?
        let url: String?

        if let pr = work.prRef {
            kind = .pr
            owner = pr.owner
            repo = pr.repo
            number = pr.number
            url = pr.url.absoluteString
        } else if let issue = work.issueRef {
            kind = .issue
            owner = issue.owner
            repo = issue.repo
            number = issue.number
            url = issue.url.absoluteString
        } else {
            kind = .task
            owner = nil
            repo = nil
            number = nil
            url = nil
        }

        return GatewayItem(
            id: work.id,
            kind: kind,
            owner: owner,
            repo: repo,
            number: number,
            url: url,
            title: work.title,
            author: work.author,
            headBranch: work.headBranch,
            baseBranch: work.baseBranch,
            attentionReason: classification.reason,
            agent: agent,
            badges: badges,
            issueStatus: issueStatus,
            label: work.label,
            isDisabled: work.disabled,
            ahead: ahead,
            behind: behind,
            localChanges: localChanges,
            lastActivityAt: work.claudeLastCompletedAt ?? work.lastOpenedAt ?? work.addedAt,
            primaryCommand: classification.primaryCommand
        )
    }

    public static func groups(
        items: [WorkItem],
        facts: [String: GatewayItemFacts],
        decorate: (WorkItem) -> Decoration
    ) -> [GatewayGroup] {
        var buckets: [GatewayGroupKind: [GatewayItem]] = [:]

        for work in items {
            guard let itemFacts = facts[work.id] else { continue }
            let decoration = decorate(work)
            let projected = item(
                from: work,
                facts: itemFacts,
                agent: decoration.agent,
                badges: decoration.badges,
                issueStatus: decoration.issueStatus,
                ahead: decoration.ahead,
                behind: decoration.behind,
                localChanges: decoration.localChanges
            )
            buckets[GatewayGrouping.classify(itemFacts).group, default: []].append(projected)
        }

        return GatewayGroupKind.allCases.compactMap { kind in
            guard let bucket = buckets[kind], !bucket.isEmpty else { return nil }
            return GatewayGroup(kind: kind, items: bucket)
        }
    }

    /// `AppModel.removeReview` deletes the worktree from disk, including uncommitted work.
    /// On a phone that is one mis-tap, so a dirty worktree can only be removed at the Mac.
    public static func removalRefusal(localChanges: Int) -> String? {
        guard localChanges > 0 else { return nil }
        return "This worktree has \(localChanges) local change\(localChanges == 1 ? "" : "s"). "
            + "Remove it at the Mac, or discard the changes there first."
    }
}
```

`GatewayGroupKind.allCases` is declared in the order `needsYou`, `running`, `queued`, `idle`, so `compactMap` over it produces exactly the ordering the client expects.

- [ ] **Step 6: Add the `GatewayBackend` conformance to the same file**

Append to `GatewayProjection.swift`:

```swift
extension AppModel: GatewayBackend {
    public func snapshot() -> GatewaySnapshot {
        let visible = reviews
        var facts: [String: GatewayItemFacts] = [:]

        for work in visible {
            let status = claudeStatuses[work.id]
            facts[work.id] = GatewayItemFacts(
                id: work.id,
                isDisabled: work.disabled,
                limitMessage: work.agentLimitMessage,
                awaitsMyResponse: work.awaitsMyResponse(myLogin: currentLogin),
                hasVerdict: work.claudeReviewedAt != nil,
                hasUnseenAuthorUpdate: hasUnseenAuthorUpdate(work),
                sessionIsLive: claudeSessions[work.id] != nil,
                isQueued: queuedReviewIDs.contains(work.id)
            )
        }

        let groups = GatewayProjection.groups(items: visible, facts: facts) { work in
            GatewayProjection.Decoration(
                agent: gatewayAgent(for: work),
                badges: gatewayBadges(for: work),
                issueStatus: manualOrDerivedIssueStatus(for: work),
                ahead: pushability[work.id]?.ahead ?? 0,
                behind: pushability[work.id]?.behind ?? 0,
                localChanges: worktreeLocalChanges[work.id] ?? 0
            )
        }

        return GatewaySnapshot(
            generatedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            login: currentLogin,
            groups: groups,
            warnings: discoveryWarnings
        )
    }

    public func perform(_ command: GatewayCommand) async -> GatewayCommandResult {
        func accept() -> GatewayCommandResult {
            GatewayCommandResult(status: .accepted, snapshot: snapshot())
        }

        switch command {
        case .refreshAll:
            await refreshAllNow()
        case .refreshItem(let id):
            await refreshReviewState(for: id)
            await refreshWorktreeCleanliness(for: id)
        case .markAuthorUpdateSeen(let id):
            await markAuthorUpdateSeen(id: id)
        case .clearWaiting(let id):
            await clearWaiting(id: id)
        case .setPane(let id, let pane):
            guard let selection = PaneSelection(rawValue: pane) else {
                return GatewayCommandResult(status: .rejected, message: "unknown pane \(pane)", snapshot: snapshot())
            }
            await setPane(selection, for: id)
        case .startSession(let id, let forceFresh):
            guard let work = reviews.first(where: { $0.id == id }) else {
                return GatewayCommandResult(status: .rejected, message: "no such item", snapshot: snapshot())
            }
            await ensureAgentSession(for: work, forceFresh: forceFresh)
        case .clearSession(let id):
            await clearAgentSession(for: id)
        case .clearAgentLimit(let id):
            await clearAgentLimit(for: id)
        case .handOver(let id):
            let moved = await handOverToFailoverAgent(for: id)
            guard moved else {
                return GatewayCommandResult(status: .rejected, message: "no failover agent is available", snapshot: snapshot())
            }
        case .addPR(let url):
            await addPR(urlString: url)
        case .addIssue(let url):
            await addIssue(urlString: url)
        case .setIssueStatus(let id, let status):
            let resolved = status.flatMap(IssueWorkStatus.init(rawValue:))
            if status != nil && resolved == nil {
                return GatewayCommandResult(status: .rejected, message: "unknown status", snapshot: snapshot())
            }
            await setIssueStatus(resolved, for: id)
        case .setLabel(let id, let label):
            await setLabel(label, for: id)
        case .setDisabled(let id, let disabled):
            await setReviewDisabled(disabled, for: id)
        case .removeItem(let id):
            if let refusal = GatewayProjection.removalRefusal(localChanges: worktreeLocalChanges[id] ?? 0) {
                return GatewayCommandResult(status: .rejected, message: refusal, snapshot: snapshot())
            }
            await removeReview(id: id)
        }

        if let error = errorMessage {
            return GatewayCommandResult(status: .rejected, message: error, snapshot: snapshot())
        }
        return accept()
    }
}
```

Write the three private helpers `gatewayAgent(for:)`, `gatewayBadges(for:)` and `manualOrDerivedIssueStatus(for:)` in a `private extension AppModel` in the same file. `gatewayBadges` reproduces the badge set from `App/ContentView.swift:568` through `:697`, carrying the same text, tone and help sentence for each. `gatewayAgent` maps `claudeStatuses[id]` and `usageToShow(for:)` onto `GatewayAgent`. `manualOrDerivedIssueStatus` calls the existing free function `resolveIssueStatus(manual:prState:claudeReviewedAt:claudeWorking:)` from `PRPilotModels` and returns its `displayName`.

- [ ] **Step 7: Run the tests**

Run: `swift test --package-path Core --filter GatewayProjectionTests`
Expected: PASS, all five tests.

- [ ] **Step 8: Run the full suite**

Run: `swift test --package-path Core`
Expected: PASS, apart from the two known flakes.

- [ ] **Step 9: Commit**

```bash
git add Core/Package.swift Core/Sources/AppCore Core/Tests/AppCoreTests/GatewayProjectionTests.swift
git commit --no-verify -m "feat(gateway): project AppModel onto the gateway backend"
```

---

### Task 10: Service lifetime, settings and app wiring

**Files:**
- Create: `Core/Sources/GatewayKit/GatewayService.swift`
- Modify: `Core/Sources/PRPilotModels/Settings.swift`
- Modify: `App/AppDelegate.swift`
- Modify: `App/SettingsView.swift`
- Modify: `project.yml`
- Test: `Core/Tests/GatewayKitTests/GatewayServiceTests.swift`
- Test: `Core/Tests/PRPilotModelsTests/SettingsTests.swift` (extend the existing file if present, otherwise create it)

**Interfaces:**
- Consumes: `GatewayRouter`, `SnapshotBroadcaster`, `CommandLedger`, `BearerTokenVerifier`.
- Produces: `GatewayService` with `start()`, `stop()`, `var isRunning: Bool`, `var tailscaleCommand: String`. `Settings.gatewayEnabled`, `Settings.gatewayPort`.

- [ ] **Step 1: Add the two settings**

In `Core/Sources/PRPilotModels/Settings.swift`, add two stored properties beside the other feature toggles:

```swift
/// Whether the remote gateway listens. Off by default — a listener nobody asked for is
/// a listener nobody is watching.
public var gatewayEnabled: Bool
public var gatewayPort: Int
```

Add both to the memberwise `init` with defaults `false` and `8776`, add them to `Settings.default`, and decode them with `decodeIfPresent` defaulting to the same values so an existing `store.json` still loads.

- [ ] **Step 2: Write the settings test**

Add to `Core/Tests/PRPilotModelsTests/SettingsTests.swift`:

```swift
@Test func theGatewayIsOffByDefaultOnPort8776() {
    #expect(Settings.default.gatewayEnabled == false)
    #expect(Settings.default.gatewayPort == 8776)
}

@Test func settingsStoredBeforeTheGatewayExistedStillDecode() throws {
    let legacy = #"{"managedRoot":"/tmp","claudeLaunchArgs":"","claudeEnv":""}"#
    let decoded = try? JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))

    // A legacy document is missing many required keys, so decoding may fail outright.
    // What must hold is that adding the gateway keys did not change that outcome: encode
    // the default, strip the two new keys, and confirm it still decodes.
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as! [String: Any]
    object.removeValue(forKey: "gatewayEnabled")
    object.removeValue(forKey: "gatewayPort")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let recovered = try JSONDecoder().decode(Settings.self, from: stripped)

    #expect(recovered.gatewayEnabled == false)
    #expect(recovered.gatewayPort == 8776)
    _ = decoded
}
```

- [ ] **Step 3: Run the settings test**

Run: `swift test --package-path Core --filter SettingsTests`
Expected: PASS.

- [ ] **Step 4: Write the service test**

`Core/Tests/GatewayKitTests/GatewayServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import GatewayKit

@Test func theServiceReportsTheTailscaleCommandForItsPort() async {
    let backend = await FakeGatewayBackend()
    let service = await GatewayService(backend: backend, port: 8776, token: "t", appVersion: "test")

    #expect(await service.tailscaleCommand == "tailscale serve --bg 8776")
}

@Test func theServiceIsNotRunningBeforeItIsStarted() async {
    let backend = await FakeGatewayBackend()
    let service = await GatewayService(backend: backend, port: 8776, token: "t", appVersion: "test")

    #expect(await service.isRunning == false)
}

@Test func startingThenStoppingLeavesTheServiceStopped() async throws {
    let backend = await FakeGatewayBackend()
    let service = await GatewayService(backend: backend, port: 0, token: "t", appVersion: "test")

    await service.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await service.isRunning)

    await service.stop()
    #expect(await service.isRunning == false)
}
```

Port 0 asks the operating system for a free port, so the test never collides with a real gateway on 8776.

- [ ] **Step 5: Run it to verify it fails**

Run: `swift test --package-path Core --filter GatewayServiceTests`
Expected: FAIL to compile — `cannot find 'GatewayService' in scope`.

- [ ] **Step 6: Write `Core/Sources/GatewayKit/GatewayService.swift`**

```swift
import Foundation
import Hummingbird

/// Owns the listener, the broadcaster and the ledger for one run of the gateway.
@MainActor
public final class GatewayService {
    private let backend: any GatewayBackend
    private let port: Int
    private let token: String
    private let appVersion: String
    private let broadcaster: SnapshotBroadcaster
    private let ledger = CommandLedger()
    private var runTask: Task<Void, Never>?

    public init(backend: any GatewayBackend, port: Int, token: String, appVersion: String) {
        self.backend = backend
        self.port = port
        self.token = token
        self.appVersion = appVersion
        self.broadcaster = SnapshotBroadcaster(backend: backend)
    }

    public var isRunning: Bool { runTask != nil }

    /// The command the user pastes to publish the gateway on their tailnet. Shown in
    /// Settings rather than run for them, because it changes their tailnet configuration.
    public var tailscaleCommand: String { "tailscale serve --bg \(port)" }

    public func start() {
        guard runTask == nil else { return }

        let router = GatewayRouter.make(
            backend: backend,
            verifier: BearerTokenVerifier(token: token),
            ledger: ledger,
            appVersion: appVersion,
            broadcaster: broadcaster
        )

        // Loopback only. The operating system then guarantees that nothing off this
        // machine can reach the listener, and `tailscale serve` is the only intended
        // local client.
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )

        runTask = Task {
            do {
                try await app.runService()
            } catch {
                // A cancelled run is the normal stop path.
            }
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await broadcaster.shutdown() }
    }
}
```

- [ ] **Step 7: Wire it into `App/AppDelegate.swift`**

Add `import GatewayKit` and a stored property:

```swift
private var gateway: GatewayService?
```

Add a method that `PRPilotApp` calls once the model has loaded, and on every settings change:

```swift
func reconcileGateway(model: AppModel) {
    let wanted = model.settings.gatewayEnabled
    if wanted, gateway == nil {
        let service = GatewayService(
            backend: model,
            port: model.settings.gatewayPort,
            token: GatewayToken.loadOrCreate(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
        service.start()
        gateway = service
    } else if !wanted, let service = gateway {
        service.stop()
        gateway = nil
    }
}
```

Stop the gateway in `applicationShouldTerminate` before the agent shutdown begins, and in `applicationWillTerminate`.

- [ ] **Step 8: Add `GatewayToken` for Keychain storage**

Create `App/GatewayToken.swift` with `static func loadOrCreate() -> String`. It reads a generic-password Keychain item with service `com.ordishs.PRPilot.gateway` and account `bearer`. When absent it generates 32 bytes from `SecRandomCopyBytes`, base64url-encodes them, stores the item with `kSecAttrAccessibleWhenUnlocked`, and returns it.

- [ ] **Step 9: Add the Settings pane controls**

In `App/SettingsView.swift`, add a "Remote" section with:

- A toggle bound to `settings.gatewayEnabled`.
- A port field bound to `settings.gatewayPort`.
- A read-only row showing `tailscale serve --bg <port>` with a copy button.
- A row showing the bearer token as a QR code, generated with `CIFilter.qrCodeGenerator()`, plus a copy button. Hide the token behind a "Show" disclosure so it is not on screen by default.

- [ ] **Step 10: Add `GatewayKit` to the app target in `project.yml`**

In the `PRPilot` target's `dependencies` list:

```yaml
      - package: PRPilotCore
        product: GatewayKit
```

- [ ] **Step 11: Run the tests and build the app**

Run: `swift test --package-path Core`
Expected: PASS, apart from the two known flakes.

Run: `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 12: Commit**

```bash
git add Core App project.yml
git commit --no-verify -m "feat(gateway): run the gateway from settings with a keychain token"
```

---

### Task 11: Client shell and list screen

**Files:**
- Create: `App/Resources/web/index.html`
- Create: `App/Resources/web/app.css`
- Create: `App/Resources/web/app.js`
- Create: `App/Resources/web/manifest.json`
- Create: `App/Resources/web/vendor/preact.mjs`
- Create: `App/Resources/web/vendor/htm.mjs`
- Create: `App/Resources/web/icon-180.png`
- Modify: `project.yml` (add `App/Resources` to the target's sources so it is copied into the bundle)
- Modify: `Core/Sources/GatewayKit/GatewayRouter.swift` (serve the bundle directory at `/`)

**Interfaces:**
- Consumes: `GET /api/snapshot`, `GET /api/events`, `GET /api/health`.
- Produces: a rendered list screen. Task 12 adds the detail screen to `app.js`.

- [ ] **Step 1: Vendor Preact and htm**

Download `preact` 10.x and `htm` 3.x as ES modules and commit them under `App/Resources/web/vendor/`. Nothing is fetched from a CDN at runtime: the phone reaches the Mac over a tunnel, and a CDN reference fails whenever you are on the tailnet but off the internet.

- [ ] **Step 2: Add static file serving to `GatewayRouter.make`**

Add a `webRoot: URL?` parameter, and when it is non-nil mount Hummingbird's `FileMiddleware(webRoot.path, searchForIndexHtml: true)` on the router. Static files carry no token, because they hold no data — every byte of state comes from a guarded `/api` route.

- [ ] **Step 3: Write `index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="manifest" href="/manifest.json">
<link rel="apple-touch-icon" href="/icon-180.png">
<link rel="stylesheet" href="/app.css">
<title>PR Pilot</title>
</head>
<body>
<div id="root"></div>
<script type="module" src="/app.js"></script>
</body>
</html>
```

- [ ] **Step 4: Write `manifest.json`**

```json
{
  "name": "PR Pilot",
  "short_name": "PR Pilot",
  "display": "standalone",
  "start_url": "/",
  "background_color": "#0e0e12",
  "theme_color": "#0e0e12",
  "icons": [{ "src": "/icon-180.png", "sizes": "180x180", "type": "image/png" }]
}
```

- [ ] **Step 5: Write the token gate, transport and list screen in `app.js`**

```js
import { h, render } from '/vendor/preact.mjs'
import { useState, useEffect, useCallback } from '/vendor/preact.mjs'
import htm from '/vendor/htm.mjs'

const html = htm.bind(h)

const TOKEN_KEY = 'prpilot.token'

function loadToken() {
  const fromUrl = new URLSearchParams(location.search).get('token')
  if (fromUrl) {
    localStorage.setItem(TOKEN_KEY, fromUrl)
    history.replaceState(null, '', location.pathname)
    return fromUrl
  }
  return localStorage.getItem(TOKEN_KEY)
}

function useSnapshot(token) {
  const [snapshot, setSnapshot] = useState(null)
  const [connected, setConnected] = useState(false)

  useEffect(() => {
    if (!token) return
    // EventSource cannot set an Authorization header, so the token travels in the
    // query string for this one route. It never leaves the tailnet, and the server
    // accepts it on /api/events only.
    const source = new EventSource(`/api/events?token=${encodeURIComponent(token)}`)
    source.onopen = () => setConnected(true)
    source.onerror = () => setConnected(false)
    source.onmessage = (event) => {
      setSnapshot(JSON.parse(event.data))
      setConnected(true)
    }
    return () => source.close()
  }, [token])

  return { snapshot, connected }
}

async function sendCommand(token, command) {
  const response = await fetch('/api/command', {
    method: 'POST',
    headers: { 'authorization': `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ commandID: crypto.randomUUID(), command }),
  })
  if (!response.ok) throw new Error(`command failed: ${response.status}`)
  return response.json()
}

const GROUP_TITLES = {
  needsYou: 'Needs you',
  running: 'Running',
  queued: 'Queued',
  idle: 'Idle',
}

function Row({ item, onOpen }) {
  return html`
    <button class="row" onClick=${() => onOpen(item.id)}>
      <div class="row-title">${item.title}</div>
      ${item.attentionReason && html`<div class="row-reason">${item.attentionReason}</div>`}
      <div class="row-meta">
        ${item.repo ? `${item.repo} #${item.number}` : 'task'}
        ${item.label ? ` · ${item.label}` : ''}
      </div>
    </button>
  `
}

function List({ snapshot, onOpen }) {
  return html`
    <div class="list">
      ${snapshot.groups.map(group => html`
        <section key=${group.kind}>
          <h2 class="group ${group.kind}">
            ${GROUP_TITLES[group.kind]} · ${group.items.length}
          </h2>
          ${group.items.map(item => html`<${Row} key=${item.id} item=${item} onOpen=${onOpen} />`)}
        </section>
      `)}
    </div>
  `
}

function TokenPrompt({ onToken }) {
  const [value, setValue] = useState('')
  return html`
    <div class="prompt">
      <h1>PR Pilot</h1>
      <p>Paste the gateway token from Settings on the Mac, or scan its QR code.</p>
      <input value=${value} onInput=${e => setValue(e.target.value)} placeholder="token" />
      <button onClick=${() => onToken(value.trim())}>Connect</button>
    </div>
  `
}

function App() {
  const [token, setToken] = useState(loadToken())
  const [openID, setOpenID] = useState(null)
  const { snapshot, connected } = useSnapshot(token)

  const saveToken = useCallback((value) => {
    localStorage.setItem(TOKEN_KEY, value)
    setToken(value)
  }, [])

  if (!token) return html`<${TokenPrompt} onToken=${saveToken} />`
  if (!snapshot) return html`<div class="prompt"><p>Connecting…</p></div>`

  return html`
    <div class="app">
      ${!connected && html`<div class="offline">Reconnecting…</div>`}
      <header class="bar">
        <span class="brand">PR Pilot</span>
        <span class="count">${snapshot.groups.reduce((n, g) => n + g.items.length, 0)} items</span>
      </header>
      <${List} snapshot=${snapshot} onOpen=${setOpenID} />
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
```

`openID` and `sendCommand` are unused until Task 12. Leave them; Task 12 consumes both.

- [ ] **Step 6: Accept the token from the query string on `/api/events` only**

`EventSource` cannot set headers. In `GatewayAuthMiddleware`, when the path is `/api/events` and no `authorization` header is present, read a `token` query parameter and synthesize `authorization: Bearer <token>` before verifying. Add a `GatewayRouterTests` case asserting that `/api/events?token=...` is accepted and `/api/snapshot?token=...` is **not** — a token in a query string lands in logs and history, so it is tolerated on the one route that cannot avoid it and nowhere else.

- [ ] **Step 7: Write `app.css`**

Mobile-first. A dark default with a light-mode override under `@media (prefers-color-scheme: light)`. Group headers tinted by kind: `needsYou` amber, `running` green, `queued` and `idle` grey. Rows are full-width buttons with a 44pt minimum height. Respect `env(safe-area-inset-bottom)`.

- [ ] **Step 8: Verify by hand**

Run the app, enable the gateway in Settings, and open `http://127.0.0.1:8776/` in Safari on the Mac with the token appended: `http://127.0.0.1:8776/?token=<token>`.

Expected: the list renders, grouped, with your real queue. Change something in the Mac app — disable an item, start a session — and confirm the list updates within about a second without a reload.

- [ ] **Step 9: Run the test suite**

Run: `swift test --package-path Core`
Expected: PASS, apart from the two known flakes. The new query-string test from Step 6 passes.

- [ ] **Step 10: Commit**

```bash
git add App Core project.yml
git commit --no-verify -m "feat(gateway): add the web client list screen"
```

---

### Task 12: Detail screen, action sheet and commands

**Files:**
- Modify: `App/Resources/web/app.js`
- Modify: `App/Resources/web/app.css`

**Interfaces:**
- Consumes: `sendCommand`, `openID` from Task 11; `GatewayItem.primaryCommand`, `badges`, `agent` from Task 2.
- Produces: the finished client.

- [ ] **Step 1: Add the detail view**

Insert into `app.js` before `App`:

```js
const PRIMARY_LABELS = {
  clearAgentLimit: 'Clear limit and resume',
  clearWaiting: 'Mark as answered',
  markAuthorUpdateSeen: 'Mark update seen',
}

function findItem(snapshot, id) {
  for (const group of snapshot.groups) {
    const found = group.items.find(item => item.id === id)
    if (found) return found
  }
  return null
}

function Detail({ item, token, onBack, onError }) {
  const [busy, setBusy] = useState(null)
  const [moreOpen, setMoreOpen] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)

  const run = async (command, key) => {
    setBusy(key)
    try {
      const result = await sendCommand(token, command)
      if (result.status === 'rejected') onError(result.message)
    } catch (error) {
      onError(String(error))
    } finally {
      setBusy(null)
    }
  }

  const primary = item.primaryCommand
  const primaryLabel = primary ? (PRIMARY_LABELS[primary.type] ?? 'Run') : 'Fresh session'
  const primaryCommand = primary ?? { type: 'startSession', id: item.id, forceFresh: true }

  return html`
    <div class="detail">
      <button class="back" onClick=${onBack}>‹ Back</button>

      <h1 class="detail-title">${item.title}</h1>
      <div class="detail-meta">
        ${item.repo ? `${item.repo} #${item.number}` : 'task'}
        ${item.author ? ` · ${item.author}` : ''}
        ${item.headBranch ? ` · ${item.headBranch}` : ''}
      </div>

      ${item.attentionReason && html`
        <div class="banner">
          <div class="banner-title">${item.attentionReason}</div>
        </div>
      `}

      ${item.agent && html`
        <div class="card">
          <div class="card-head">
            <span class="agent-kind">${item.agent.kind}</span>
            <span class="agent-stat">
              ${item.agent.elapsedSeconds != null ? `${Math.round(item.agent.elapsedSeconds / 60)}m` : ''}
              ${item.agent.usedPercent != null ? ` · ${item.agent.usedPercent}%` : ''}
            </span>
          </div>
          ${item.agent.verdict && html`<p class="verdict">${item.agent.verdict}</p>`}
        </div>
      `}

      ${item.badges.length > 0 && html`
        <div class="label">State</div>
        <div class="badges">
          ${item.badges.map(badge => html`
            <span key=${badge.text} class="badge ${badge.tone}" title=${badge.help}>${badge.text}</span>
          `)}
        </div>
      `}

      <div class="label">Branch</div>
      <div class="facts">
        base ${item.baseBranch} · ↑${item.ahead} ↓${item.behind}
        ${item.localChanges > 0 ? ` · ${item.localChanges} local` : ''}
      </div>

      ${item.url && html`<a class="external" href=${item.url} target="_blank" rel="noreferrer">Open on GitHub ↗</a>`}

      <div class="sheet-spacer"></div>

      <div class="sheet">
        <div class="grabber"></div>
        <button class="primary" disabled=${busy !== null} onClick=${() => run(primaryCommand, 'primary')}>
          ${busy === 'primary' ? 'Working…' : primaryLabel}
        </button>
        <div class="sheet-row">
          <button disabled=${busy !== null}
                  onClick=${() => run({ type: 'startSession', id: item.id, forceFresh: true }, 'fresh')}>
            ${busy === 'fresh' ? '…' : 'Fresh session'}
          </button>
          <button disabled=${busy !== null}
                  onClick=${() => run({ type: 'handOver', id: item.id }, 'handover')}>
            ${busy === 'handover' ? '…' : 'Hand over'}
          </button>
          <button class="more" onClick=${() => setMoreOpen(!moreOpen)}>•••</button>
        </div>

        ${moreOpen && html`
          <div class="more-menu">
            <button disabled=${busy !== null} onClick=${() => run({ type: 'refreshItem', id: item.id }, 'refresh')}>Refresh</button>
            <button disabled=${busy !== null} onClick=${() => run({ type: 'clearSession', id: item.id }, 'clear')}>Clear session</button>
            <button disabled=${busy !== null}
                    onClick=${() => run({ type: 'setDisabled', id: item.id, disabled: !item.isDisabled }, 'disable')}>
              ${item.isDisabled ? 'Enable' : 'Disable'}
            </button>
            ${confirmRemove
              ? html`<button class="danger" disabled=${busy !== null}
                             onClick=${() => run({ type: 'removeItem', id: item.id }, 'remove')}>
                       Really remove — deletes the worktree
                     </button>`
              : html`<button class="danger" onClick=${() => setConfirmRemove(true)}>Remove from list</button>`}
          </div>
        `}
      </div>
    </div>
  `
}
```

- [ ] **Step 2: Route between list and detail in `App`**

Replace the final `return` in `App` with:

```js
  const open = openID ? findItem(snapshot, openID) : null

  return html`
    <div class="app">
      ${!connected && html`<div class="offline">Reconnecting…</div>`}
      ${error && html`<div class="error" onClick=${() => setError(null)}>${error}</div>`}
      ${open
        ? html`<${Detail} item=${open} token=${token} onBack=${() => setOpenID(null)} onError=${setError} />`
        : html`
          <header class="bar">
            <span class="brand">PR Pilot</span>
            <span class="count">${snapshot.groups.reduce((n, g) => n + g.items.length, 0)} items</span>
          </header>
          <${List} snapshot=${snapshot} onOpen=${setOpenID} />
        `}
    </div>
  `
```

Add `const [error, setError] = useState(null)` beside the other `useState` calls in `App`.

When an item is removed, `findItem` returns `null` on the next snapshot and the detail view disappears. Add `if (openID && !open) { setOpenID(null) }` inside a `useEffect` on `[openID, snapshot]` so the client returns to the list rather than rendering nothing.

- [ ] **Step 3: Extend `app.css`**

Style `.detail`, `.banner`, `.card`, `.verdict`, `.badges`, `.badge` per tone, and `.sheet`. The sheet is `position: fixed; bottom: 0` with `padding-bottom: calc(12px + env(safe-area-inset-bottom))`. `.sheet-spacer` is tall enough that the last fact clears the sheet.

- [ ] **Step 4: Verify every command by hand**

For each of the commands below, tap it in Safari and confirm the Mac app changes accordingly:

- `startSession` — an agent session appears in the Mac sidebar.
- `clearSession` — it disappears.
- `clearAgentLimit` — the Limit badge clears on the Mac.
- `clearWaiting` — the Agent badge clears.
- `markAuthorUpdateSeen` — the Author badge clears.
- `handOver` — the item moves to the failover agent, or the client shows the rejection message when no failover is available.
- `refreshItem` — the PR state refreshes.
- `setDisabled` — the item greys out on the Mac and moves to Idle on the phone.
- `removeItem` on a clean worktree — the item goes.
- `removeItem` on a dirty worktree — the client shows the refusal, and the item is still there on the Mac.

The last one is the important one. Make a worktree dirty on purpose with `touch` inside it before testing it.

- [ ] **Step 5: Confirm no git command exists**

Run: `grep -rn "push\|rebase" App/Resources/web/app.js`
Expected: no match that is a command type. If one exists, it is a bug — delete it.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path Core`
Expected: PASS, apart from the two known flakes.

- [ ] **Step 7: Commit**

```bash
git add App
git commit --no-verify -m "feat(gateway): add the detail screen and command sheet"
```

---

### Task 13: End-to-end verification over Tailscale

This task writes no code. It proves the feature works on the device it was built for.

**Files:** none.

- [ ] **Step 1: Publish the gateway**

Run: `tailscale serve --bg 8776`
Then: `tailscale serve status`
Expected: the status lists the `*.ts.net` URL proxying to `127.0.0.1:8776`.

- [ ] **Step 2: Record the identity headers, closing the spec's open item**

With the gateway running, from a second tailnet device request `/api/health` and capture the full request headers the Mac receives. Add a temporary log line in `GatewayAuthMiddleware` that prints `lowered`, run the request, then remove the log line.

Record the result in the spec's "Open items" section: either the tailnet header name that arrived, or that none did. Commit that spec edit. Authentication does not change either way — this only decides whether the snapshot can display the connected tailnet user.

- [ ] **Step 3: Install on the phone**

Open the `*.ts.net` URL in Safari on the iPhone. Paste or scan the token. Add to Home Screen.

Expected: the icon appears, and opening it launches without Safari chrome.

- [ ] **Step 4: Confirm it is not reachable off the tailnet**

Turn Tailscale off on the phone and reload.
Expected: the page fails to load. If it loads, STOP — something is listening on a routable interface, or `tailscale funnel` is on. Neither is acceptable.

- [ ] **Step 5: Confirm live updates on the phone**

With the phone showing the list, start an agent session at the Mac.
Expected: the item moves to Running within about a second, with no reload and no scroll jump.

- [ ] **Step 6: Confirm reconnection**

Turn the phone's Wi-Fi off for 30 seconds and back on.
Expected: the "Reconnecting…" bar appears, then clears on its own, and the list is current. No reload needed.

- [ ] **Step 7: Confirm idempotency**

Tap a primary action, then immediately background and reopen the app.
Expected: the command ran exactly once. Check the Mac — one session started, not two.

- [ ] **Step 8: Report**

Write up the results with the literal commands and their output. Report any step that did not behave as expected rather than describing the feature as working.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: module boundary and package changes (Task 1), concurrency and the `GatewayBackend` protocol (Tasks 4 and 9), change detection (Task 8), lifetime and Settings (Task 10), routes (Tasks 7 and 8), wire types (Task 2), grouping rule (Task 3), commands and backing methods (Tasks 4 and 9), the `removeItem` guard (Tasks 9 and 12), authentication (Task 6), idempotency (Task 5), client delivery, rendering, list, detail, state, connection and home-screen install (Tasks 11 and 12), and testing (throughout, plus Task 13 for the end-to-end run). The spec's one open item is closed in Task 13 Step 2.

**Known ordering wrinkle.** Task 2 does not compile until Task 4 lands, because `GatewayItem.primaryCommand` is a `GatewayCommand`. This is called out in Task 2 Step 3 with a single shared commit at Task 4 Step 6. Every other task is green on its own.

**Type consistency.** `GatewayGroupKind` cases `needsYou`, `running`, `queued`, `idle` are used identically in Tasks 2, 3, 9 and 11. `GatewayItemFacts` field names match between Tasks 3 and 9. `GatewayCommand` case names match between Tasks 4, 9, 11 and 12, and the JavaScript `type` strings in Task 12 match the Swift decoder's `case` strings in Task 4. `sendCommand` is defined in Task 11 and consumed in Task 12. `SnapshotBroadcaster.poke()` is referenced in Task 7 and defined in Task 8, which Task 7 Step 4 states explicitly.

**Deliberate gaps, restated.** The client has no automated tests. Tasks 11, 12 and 13 verify it by hand, and Task 13 requires reporting what actually happened rather than asserting success.
