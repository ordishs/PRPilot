# Phone Detail Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the phone web client's item flow match the Mac: a GitHub | Agent pane switch, the live conversation as the Agent pane, the Mac's rebase banner, per-item agent menu, and the Mac context-menu actions that are safe to run from a phone.

**Architecture:** Add one `GatewayDetail` struct to each `GatewayItem` on the wire (wire version 3) and one new command, `setAgent`. `GatewayProjection` builds the detail from `AppModel` state. A new pure module `detail.mjs` holds the client rules (node-tested). `app.js` renders them. No git command is added.

**Tech Stack:** Swift 6 package (`Core`, Swift Testing), Hummingbird gateway, Preact + htm web client, `node --test`.

**Spec:** None written. The design was approved in chat on 2026-10-13. It is the "Proposed design (option 3)" list: panes, agent pane, GitHub pane, read-only rebase banner, actions menu, `setAgent`, wire 2 → 3.

## Global Constraints

- `GatewayCommand` never gains `push`, `rebase`, `continueRebase`, `abortRebase`, `forcePush` or `discardLocalChanges`. `theClientNeverSendsAGitCommand` must stay green.
- Gateway wire version goes `2` → `3` in `Core/Sources/GatewayKit/GatewayVersion.swift`.
- No comments in new code unless the surrounding file already uses one for the same kind of fact. No AI attribution in commit messages. Commit subjects use conventional commits (`feat(gateway): ...`).
- Swift test command: `cd Core && swift test`. Node test command: `node --test scripts/web-client.test.mjs`.
- `sendPrompt` stays gated by `settings.gatewayAllowPrompts`. The Agent pane shows the existing "off" rejection text, and does not bypass it.
- Remove stays refused when the worktree has local changes (`GatewayProjection.removalRefusal`).
- The Mac context-menu items not offered on the phone: Rebase, Push, Discard Local Changes, Copy Worktree Path.

## Review Focus

- Item has no worktree and no session: Agent pane shows the Mac "idle/preparing" state and a Start button, not a blank pane.
- Disabled item: Agent segment is disabled, GitHub pane is forced (Mac `resolvedPane`).
- Task item (no URL): GitHub pane shows no dead "Open on GitHub" link; default pane is Agent.
- Item removed on the Mac while its detail screen is open: client falls back to the list (existing behaviour, must survive the rewrite).
- Old client cached on the phone against a wire-3 server, or the reverse: `GatewayDetail` decodes when absent (old server) and the client must not crash when `item.detail` is undefined.
- Switching agent mid-run kills the live session (`AppModel.setAgent` terminates it): the menu must confirm before sending `setAgent` when `agent.status` is `working`.

---

### Task 1: Wire format — `GatewayDetail`, `setAgent`, version 3

**Files:**
- Modify: `Core/Sources/GatewayKit/GatewayVersion.swift`
- Modify: `Core/Sources/GatewayKit/GatewayCommand.swift`
- Modify: `Core/Sources/GatewayKit/GatewaySnapshot.swift`
- Test: `Core/Tests/GatewayKitTests/GatewayCommandTests.swift`
- Test: `Core/Tests/GatewayKitTests/GatewaySnapshotTests.swift`

**Interfaces:**
- Produces: `GatewayCommand.setAgent(id: String, agent: String?)`; `GatewayRebase`; `GatewayDetail` (+ `.empty`); `GatewayItem.detail: GatewayDetail`; `GatewayListing.agents/issueStatuses: [GatewayOption]`, `defaultAgent: String`, `failoverAgent: String`.

- [ ] **Step 1: Write failing tests.** Append to `GatewayCommandTests.swift`:

```swift
@Test func setAgentCarriesItsChoice() throws {
    #expect(
        try decode(#"{"type":"setAgent","id":"a#1","agent":"codex"}"#)
            == .setAgent(id: "a#1", agent: "codex")
    )
}

@Test func setAgentWithNoAgentMeansFollowTheDefault() throws {
    #expect(
        try decode(#"{"type":"setAgent","id":"a#1"}"#)
            == .setAgent(id: "a#1", agent: nil)
    )
}

@Test func setAgentSurvivesARoundTrip() throws {
    let command = GatewayCommand.setAgent(id: "a#1", agent: "pi")
    let data = try JSONEncoder().encode(command)
    #expect(try JSONDecoder().decode(GatewayCommand.self, from: data) == command)
}
```

Append to `GatewaySnapshotTests.swift`:

```swift
@Test func anItemWithoutADetailDecodesWithAnEmptyOne() throws {
    let item = sampleItem()
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
    object.removeValue(forKey: "detail")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(GatewayItem.self, from: data)

    #expect(decoded.detail == .empty)
}

@Test func theDetailSurvivesARoundTrip() throws {
    var item = sampleItem()
    item.detail = GatewayDetail(
        pane: "claude",
        paneState: "failed",
        paneMessage: "worktree failed",
        runLabel: "started today",
        rebase: GatewayRebase(state: "conflicted", files: ["a.go"], message: nil),
        agentChoice: "codex",
        agentKey: "codex",
        canHandOver: true,
        sessionID: "abc",
        canClearAgentBadge: true,
        canClearAuthorBadge: false,
        canClearLimit: true
    )

    let data = try JSONEncoder().encode(item)

    #expect(try JSONDecoder().decode(GatewayItem.self, from: data) == item)
}

@Test func theWireVersionIsThree() {
    #expect(GatewayVersion.current == 3)
}
```

- [ ] **Step 2: Run and see failures.** `cd Core && swift test --filter GatewayKitTests` → build errors for `setAgent`, `GatewayDetail`.

- [ ] **Step 3: Implement.** `GatewayVersion.swift`: `current = 3`.

`GatewayCommand.swift`: add `case setAgent(id: String, agent: String?)` after `setDisabled`; add `agent` to `CodingKeys`; decode:

```swift
        case "setAgent":
            self = .setAgent(
                id: try id(),
                agent: try c.decodeIfPresent(String.self, forKey: .agent)
            )
```

encode:

```swift
        case .setAgent(let id, let agent):
            try c.encode("setAgent", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(agent, forKey: .agent)
```

`GatewaySnapshot.swift`: add before `GatewayItem`:

```swift
public struct GatewayRebase: Codable, Sendable, Hashable {
    public var state: String
    public var files: [String]
    public var message: String?

    public init(state: String, files: [String] = [], message: String? = nil) {
        self.state = state
        self.files = files
        self.message = message
    }
}

public struct GatewayDetail: Codable, Sendable, Hashable {
    public var pane: String
    public var paneState: String
    public var paneMessage: String?
    public var runLabel: String?
    public var rebase: GatewayRebase?
    public var agentChoice: String?
    public var agentKey: String
    public var canHandOver: Bool
    public var sessionID: String?
    public var canClearAgentBadge: Bool
    public var canClearAuthorBadge: Bool
    public var canClearLimit: Bool

    public init(
        pane: String = "github",
        paneState: String = "idle",
        paneMessage: String? = nil,
        runLabel: String? = nil,
        rebase: GatewayRebase? = nil,
        agentChoice: String? = nil,
        agentKey: String = "claudeCode",
        canHandOver: Bool = false,
        sessionID: String? = nil,
        canClearAgentBadge: Bool = false,
        canClearAuthorBadge: Bool = false,
        canClearLimit: Bool = false
    ) {
        self.pane = pane
        self.paneState = paneState
        self.paneMessage = paneMessage
        self.runLabel = runLabel
        self.rebase = rebase
        self.agentChoice = agentChoice
        self.agentKey = agentKey
        self.canHandOver = canHandOver
        self.sessionID = sessionID
        self.canClearAgentBadge = canClearAgentBadge
        self.canClearAuthorBadge = canClearAuthorBadge
        self.canClearLimit = canClearLimit
    }

    public static let empty = GatewayDetail()
}
```

In `GatewayItem`: add `public var detail: GatewayDetail`; add init param `detail: GatewayDetail = .empty` after `statusRank` and assign it. `GatewayItem` has a synthesized `Decodable`; to decode when `detail` is absent, add:

```swift
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(GatewayItemKind.self, forKey: .kind)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        attentionReason = try c.decodeIfPresent(String.self, forKey: .attentionReason)
        agent = try c.decodeIfPresent(GatewayAgent.self, forKey: .agent)
        badges = try c.decode([GatewayBadge].self, forKey: .badges)
        issueStatus = try c.decodeIfPresent(String.self, forKey: .issueStatus)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        isDisabled = try c.decode(Bool.self, forKey: .isDisabled)
        ahead = try c.decode(Int.self, forKey: .ahead)
        behind = try c.decode(Int.self, forKey: .behind)
        localChanges = try c.decode(Int.self, forKey: .localChanges)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        primaryCommand = try c.decodeIfPresent(GatewayCommand.self, forKey: .primaryCommand)
        signals = try c.decode([String].self, forKey: .signals)
        resources = try c.decode([String].self, forKey: .resources)
        isParked = try c.decode(Bool.self, forKey: .isParked)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        statusRank = try c.decode(Int.self, forKey: .statusRank)
        detail = try c.decodeIfPresent(GatewayDetail.self, forKey: .detail) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, owner, repo, number, url, title, author, headBranch, baseBranch
        case attentionReason, agent, badges, issueStatus, label, isDisabled, ahead, behind
        case localChanges, lastActivityAt, primaryCommand, signals, resources, isParked
        case addedAt, statusRank, detail
    }
```

In `GatewayListing`: add `public var agents: [GatewayOption]`, `issueStatuses: [GatewayOption]`, `defaultAgent: String`, `failoverAgent: String`; init params with defaults `[]`, `[]`, `"claudeCode"`, `"claudeCode"` appended after `hideParked`; update `.empty` (defaults cover it).

- [ ] **Step 4: Run.** `cd Core && swift test --filter GatewayKitTests` → PASS. Fix every `switch` over `GatewayCommand` the compiler flags in `GatewayKit` (none expected besides coding).

- [ ] **Step 5: Commit.**

```bash
git add Core/Sources/GatewayKit Core/Tests/GatewayKitTests
git commit --no-verify -m "feat(gateway): add item detail and setAgent to the wire format"
```

---

### Task 2: Projection and backend — fill the detail, run `setAgent`

**Files:**
- Modify: `Core/Sources/AppCore/GatewayProjection.swift`
- Modify: `Core/Sources/AppCore/GatewayBackend+AppModel.swift`
- Test: `Core/Tests/AppCoreTests/GatewayProjectionTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `GatewayProjection.paneState(_ state: ClaudePaneState?, hasLiveSession: Bool) -> (state: String, message: String?)`; `GatewayProjection.rebase(_ state: AppModel.RebaseState?) -> GatewayRebase?`; `Decoration.detail: GatewayDetail` (default `.empty`); `GatewayProjection.listing(sort:hideParked:defaultAgent:failoverAgent:)`.

- [ ] **Step 1: Write failing tests.** Append to `GatewayProjectionTests.swift`:

```swift
@Test func aLivePaneStateNeedsALiveSession() {
    #expect(GatewayProjection.paneState(.sessionLive, hasLiveSession: true).state == "live")
    #expect(GatewayProjection.paneState(.sessionLive, hasLiveSession: false).state == "preparing")
}

@Test func paneStatesMapToTheMacStatesAndKeepTheirMessage() {
    #expect(GatewayProjection.paneState(nil, hasLiveSession: false).state == "idle")
    #expect(GatewayProjection.paneState(.idle, hasLiveSession: false).state == "idle")
    #expect(GatewayProjection.paneState(.preparingWorktree, hasLiveSession: false).state == "preparing")

    let failed = GatewayProjection.paneState(.worktreeFailed("no space"), hasLiveSession: false)
    #expect(failed.state == "failed")
    #expect(failed.message == "no space")

    let missing = GatewayProjection.paneState(.claudeUnavailable("claude not found"), hasLiveSession: false)
    #expect(missing.state == "unavailable")
    #expect(missing.message == "claude not found")
}

@Test func aConflictedRebaseCarriesItsFilesAndAFailedOneItsMessage() {
    let conflicted = GatewayProjection.rebase(.conflicted(["a.go", "b.go"]))
    #expect(conflicted == GatewayRebase(state: "conflicted", files: ["a.go", "b.go"], message: nil))

    let failed = GatewayProjection.rebase(.failed("boom"))
    #expect(failed == GatewayRebase(state: "failed", files: [], message: "boom"))

    #expect(GatewayProjection.rebase(nil) == nil)
}

@Test func theListingOffersEveryAgentAndTheMacIssueStatusesInMacOrder() {
    let listing = GatewayProjection.listing(
        sort: .recent, hideParked: false, defaultAgent: .codex, failoverAgent: .pi
    )

    #expect(listing.agents.map(\.key) == ["claudeCode", "pi", "codex"])
    #expect(listing.issueStatuses.map(\.key) == ["onHold", "done", "inReview", "reviewed", "new"])
    #expect(listing.defaultAgent == "codex")
    #expect(listing.failoverAgent == "pi")
}

@Test func theDecorationDetailTravelsOntoTheWireItem() {
    var decoration = plainDecoration
    decoration.detail = GatewayDetail(pane: "claude", runLabel: "started today")

    let wire = GatewayProjection.item(
        from: prItem(),
        facts: noFacts("bsv-blockchain/teranode#4788"),
        sidebar: SidebarItemFacts(),
        decoration: decoration
    )

    #expect(wire.detail.pane == "claude")
    #expect(wire.detail.runLabel == "started today")
}
```

(If `SidebarItemFacts()` has no default init, copy the construction used by the existing `aPullRequestProjectsItsIdentityOntoTheWireItem` test.)

- [ ] **Step 2: Run.** `cd Core && swift test --filter GatewayProjectionTests` → FAIL (missing symbols).

- [ ] **Step 3: Implement** in `GatewayProjection.swift`.

Add `public var detail: GatewayDetail` to `Decoration`; add init parameter `detail: GatewayDetail = .empty` last; assign. In `item(from:...)` pass `detail: decoration.detail` to `GatewayItem`.

Add:

```swift
    public static func paneState(
        _ state: ClaudePaneState?,
        hasLiveSession: Bool
    ) -> (state: String, message: String?) {
        switch state ?? .idle {
        case .idle: return ("idle", nil)
        case .preparingWorktree: return ("preparing", nil)
        case .worktreeFailed(let message): return ("failed", message)
        case .claudeUnavailable(let message): return ("unavailable", message)
        case .sessionLive: return (hasLiveSession ? "live" : "preparing", nil)
        }
    }

    public static func rebase(_ state: AppModel.RebaseState?) -> GatewayRebase? {
        switch state {
        case .conflicted(let files): return GatewayRebase(state: "conflicted", files: files)
        case .failed(let message): return GatewayRebase(state: "failed", message: message)
        case nil: return nil
        }
    }
```

Replace `listing(sort:hideParked:)` with:

```swift
    public static func listing(
        sort: SidebarSort,
        hideParked: Bool,
        defaultAgent: AgentKind,
        failoverAgent: AgentKind
    ) -> GatewayListing {
        let statuses: [IssueWorkStatus] = [.onHold, .done, .inReview, .reviewed, .new]

        return GatewayListing(
            signalFilters: SignalFilter.ordered.map {
                GatewayOption(key: $0.key, label: $0.displayName, help: $0.help)
            },
            resourceFilters: ResourceFilter.ordered.map {
                GatewayOption(key: $0.key, label: $0.displayName, help: $0.help)
            },
            sorts: SidebarSort.allCases.map {
                GatewayOption(key: $0.rawValue, label: $0.displayName, help: "")
            },
            sort: sort.rawValue,
            hideParked: hideParked,
            agents: AgentKind.allCases.map {
                GatewayOption(key: $0.rawValue, label: $0.displayName, help: "")
            },
            issueStatuses: statuses.map {
                GatewayOption(key: $0.rawValue, label: $0.displayName, help: "")
            },
            defaultAgent: defaultAgent.rawValue,
            failoverAgent: failoverAgent.rawValue
        )
    }
```

Add `import AgentKit` only if `AgentKind` is not already visible (it is in `PRPilotModels`). Update the existing `theListingWordsEveryPillAndSortTheWayTheMacDoes` test to the new signature.

In `GatewayBackend+AppModel.swift`:

1. In `snapshot()` pass new listing arguments: `defaultAgent: settings.defaultAgent, failoverAgent: settings.failoverAgent`.
2. In `decorate:` add `detail: gatewayDetail(for: work)`.
3. Add to the extension:

```swift
    func gatewayDetail(for work: WorkItem) -> GatewayDetail {
        let pane = GatewayProjection.paneState(
            claudePaneState[work.id],
            hasLiveSession: claudeSessions[work.id] != nil
        )

        return GatewayDetail(
            pane: resolvedPane(for: work).rawValue,
            paneState: pane.state,
            paneMessage: pane.message,
            runLabel: agentRunLabel(
                startedAt: work.agentRunStartedAt,
                lastCompletedAt: work.claudeLastCompletedAt
            ),
            rebase: GatewayProjection.rebase(rebaseStates[work.id]),
            agentChoice: work.agent?.rawValue,
            agentKey: work.effectiveAgent(default: settings.defaultAgent).rawValue,
            canHandOver: canHandOver(work),
            sessionID: work.claudeSessionID,
            canClearAgentBadge: work.awaitsMyResponse(myLogin: currentLogin),
            canClearAuthorBadge: work.prRef != nil && hasUnseenAuthorUpdate(work),
            canClearLimit: work.agentLimitedAt != nil
        )
    }
```

4. In `perform`, add the case:

```swift
        case .setAgent(let id, let agent):
            let kind = agent.flatMap(AgentKind.init(rawValue:))
            if agent != nil, kind == nil {
                return rejection("unknown agent \(agent ?? "")")
            }
            guard reviews.contains(where: { $0.id == id }) else {
                return rejection("no such item")
            }
            await setAgent(kind, for: id)
```

- [ ] **Step 4: Run.** `cd Core && swift test --filter "GatewayProjectionTests|GatewayKitTests"` → PASS. Then `cd Core && swift build` to confirm the app target compiles (the `App` target is built in Task 6).

- [ ] **Step 5: Commit.**

```bash
git add Core/Sources/AppCore Core/Tests/AppCoreTests
git commit --no-verify -m "feat(gateway): project pane state, rebase state and agent choice for the phone"
```

---

### Task 3: Client rules — `detail.mjs`

**Files:**
- Create: `App/Resources/web/detail.mjs`
- Test: `scripts/web-client.test.mjs`

**Interfaces:**
- Produces (all pure, no DOM): `detailOf(item)`; `availablePanes(item)`; `activePane(item, chosen)`; `needsSession(item)`; `agentOptions(snapshot, item)`; `itemActions(snapshot, item)` returning `[{ key, label, command?, prompt?, confirm?, danger?, copy? }]`.

- [ ] **Step 1: Write failing tests.** Add the import and tests to `scripts/web-client.test.mjs`:

```js
import {
  detailOf,
  availablePanes,
  activePane,
  needsSession,
  agentOptions,
  itemActions,
} from '../App/Resources/web/detail.mjs'

const listing = {
  agents: [
    { key: 'claudeCode', label: 'Claude Code' },
    { key: 'pi', label: 'pi' },
    { key: 'codex', label: 'Codex' },
  ],
  issueStatuses: [
    { key: 'onHold', label: 'On hold' },
    { key: 'done', label: 'Done' },
  ],
  defaultAgent: 'claudeCode',
  failoverAgent: 'codex',
}

const snap = { listing }

function detailItem(overrides = {}, detail = {}) {
  return item({
    id: 'o/r#1',
    kind: 'pr',
    url: 'https://github.com/o/r/pull/1',
    isDisabled: false,
    agent: null,
    detail: {
      pane: 'github',
      paneState: 'idle',
      agentKey: 'claudeCode',
      agentChoice: null,
      canHandOver: false,
      sessionID: null,
      canClearAgentBadge: false,
      canClearAuthorBadge: false,
      canClearLimit: false,
      ...detail,
    },
    ...overrides,
  })
}

test('an item from an older server has an empty detail rather than none', () => {
  const old = detailItem()
  delete old.detail
  assert.equal(detailOf(old).pane, 'github')
  assert.equal(detailOf(old).paneState, 'idle')
})

test('a disabled item offers only the GitHub pane and stays on it', () => {
  const disabled = detailItem({ isDisabled: true }, { pane: 'claude' })
  assert.deepEqual(availablePanes(disabled), ['github'])
  assert.equal(activePane(disabled, null), 'github')
})

test('an item offers both panes and opens on the remembered one', () => {
  const pr = detailItem({}, { pane: 'claude' })
  assert.deepEqual(availablePanes(pr), ['claude', 'github'])
  assert.equal(activePane(pr, null), 'claude')
  assert.equal(activePane(pr, 'github'), 'github')
})

test('a choice of the agent pane on a disabled item is ignored', () => {
  assert.equal(activePane(detailItem({ isDisabled: true }), 'claude'), 'github')
})

test('the agent pane asks for a session only while it is idle', () => {
  assert.equal(needsSession(detailItem({}, { paneState: 'idle' })), true)
  assert.equal(needsSession(detailItem({}, { paneState: 'live' })), false)
  assert.equal(needsSession(detailItem({}, { paneState: 'preparing' })), false)
  assert.equal(needsSession(detailItem({}, { paneState: 'failed' })), false)
  assert.equal(needsSession(detailItem({ isDisabled: true }, { paneState: 'idle' })), false)
})

test('the agent menu marks the current choice and leads with the default', () => {
  const options = agentOptions(snap, detailItem({}, { agentChoice: 'pi', agentKey: 'pi' }))
  assert.deepEqual(options.map((o) => o.label), [
    'Default (Claude Code)',
    'Claude Code',
    'pi',
    'Codex',
  ])
  assert.deepEqual(options.map((o) => o.checked), [false, false, true, false])
  assert.deepEqual(options[0].command, { type: 'setAgent', id: 'o/r#1', agent: null })
  assert.deepEqual(options[3].command, { type: 'setAgent', id: 'o/r#1', agent: 'codex' })
})

test('a default-following item checks the Default entry', () => {
  const options = agentOptions(snap, detailItem())
  assert.equal(options[0].checked, true)
})

test('the agent menu asks for confirmation while the agent is working', () => {
  const working = detailItem({ agent: { kind: 'Claude Code', status: 'working' } })
  assert.ok(agentOptions(snap, working).every((o) => o.confirm))
  assert.ok(agentOptions(snap, detailItem()).every((o) => !o.confirm))
})

test('hand over appears in the actions only when the item can be handed over', () => {
  const blocked = detailItem({}, { canHandOver: true })
  const actions = itemActions(snap, blocked)
  assert.ok(actions.find((a) => a.key === 'handOver').label.includes('Codex'))
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'handOver'), undefined)
})

test('badge clears appear only when there is a badge to clear', () => {
  const none = itemActions(snap, detailItem()).map((a) => a.key)
  assert.ok(!none.includes('clearAgentBadge'))
  assert.ok(!none.includes('clearAuthorBadge'))
  assert.ok(!none.includes('clearLimit'))

  const all = itemActions(
    snap,
    detailItem({}, { canClearAgentBadge: true, canClearAuthorBadge: true, canClearLimit: true })
  ).map((a) => a.key)
  assert.ok(all.includes('clearAgentBadge'))
  assert.ok(all.includes('clearAuthorBadge'))
  assert.ok(all.includes('clearLimit'))
})

test('set status is offered for issues and not for pull requests', () => {
  const issue = itemActions(snap, detailItem({ kind: 'issue' }))
  const status = issue.find((a) => a.key === 'setStatus')
  assert.deepEqual(status.choices.map((c) => c.label), ['On hold', 'Done', 'Clear (Auto)'])
  assert.deepEqual(status.choices[2].command, { type: 'setIssueStatus', id: 'o/r#1', status: null })
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'setStatus'), undefined)
})

test('copy session id needs a session id', () => {
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'copySession'), undefined)
  const withSession = itemActions(snap, detailItem({}, { sessionID: 'abc' }))
  assert.equal(withSession.find((a) => a.key === 'copySession').copy, 'abc')
})

test('clear session needs a session id', () => {
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'clearSession'), undefined)
  const withSession = itemActions(snap, detailItem({}, { sessionID: 'abc' }))
  assert.deepEqual(withSession.find((a) => a.key === 'clearSession').command, {
    type: 'clearSession',
    id: 'o/r#1',
  })
})

test('label edits prompt and clearing needs an existing label', () => {
  const unlabeled = itemActions(snap, detailItem())
  assert.equal(unlabeled.find((a) => a.key === 'label').label, 'Add Label…')
  assert.equal(unlabeled.find((a) => a.key === 'clearLabel'), undefined)

  const labeled = itemActions(snap, detailItem({ label: 'urgent' }))
  assert.equal(labeled.find((a) => a.key === 'label').label, 'Edit Label…')
  assert.deepEqual(labeled.find((a) => a.key === 'clearLabel').command, {
    type: 'setLabel',
    id: 'o/r#1',
    label: null,
  })
})

test('enable and disable flip with the item, and remove is destructive', () => {
  const on = itemActions(snap, detailItem())
  assert.deepEqual(on.find((a) => a.key === 'toggleDisabled').command, {
    type: 'setDisabled',
    id: 'o/r#1',
    disabled: true,
  })
  const off = itemActions(snap, detailItem({ isDisabled: true }))
  assert.equal(off.find((a) => a.key === 'toggleDisabled').label, 'Enable')
  assert.equal(on.find((a) => a.key === 'remove').danger, true)
  assert.equal(on.find((a) => a.key === 'remove').confirm.includes('worktree'), true)
})

test('no action ever names a git command', () => {
  const everything = itemActions(
    snap,
    detailItem(
      { kind: 'issue', label: 'x' },
      { canHandOver: true, sessionID: 's', canClearAgentBadge: true, canClearAuthorBadge: true, canClearLimit: true }
    )
  )
  const types = JSON.stringify(everything)
  for (const forbidden of ['push', 'rebase', 'continueRebase', 'abortRebase', 'discard']) {
    assert.ok(!types.toLowerCase().includes(`"type":"${forbidden.toLowerCase()}`))
  }
})
```

(`item()` in this test file takes overrides; `detailItem` spreads them last so `detail`/`agent`/`kind` overrides win. If `item()` does not spread unknown keys, extend it in this step.)

- [ ] **Step 2: Run.** `node --test scripts/web-client.test.mjs` → FAIL (module not found).

- [ ] **Step 3: Implement** `App/Resources/web/detail.mjs`:

```js
const EMPTY = {
  pane: 'github',
  paneState: 'idle',
  paneMessage: null,
  runLabel: null,
  rebase: null,
  agentChoice: null,
  agentKey: 'claudeCode',
  canHandOver: false,
  sessionID: null,
  canClearAgentBadge: false,
  canClearAuthorBadge: false,
  canClearLimit: false,
}

export function detailOf(item) {
  return { ...EMPTY, ...(item.detail || {}) }
}

export function availablePanes(item) {
  return item.isDisabled ? ['github'] : ['claude', 'github']
}

export function activePane(item, chosen) {
  const panes = availablePanes(item)
  if (chosen && panes.includes(chosen)) return chosen
  return panes.includes(detailOf(item).pane) ? detailOf(item).pane : 'github'
}

export function needsSession(item) {
  return !item.isDisabled && detailOf(item).paneState === 'idle'
}

function label(listing, key) {
  return listing.agents.find((agent) => agent.key === key)?.label ?? key
}

export function agentOptions(snapshot, item) {
  const { listing } = snapshot
  const detail = detailOf(item)
  const confirm = item.agent?.status === 'working'
    ? 'The agent is working. Switching ends its live session.'
    : null
  const command = (agent) => ({ type: 'setAgent', id: item.id, agent })

  return [
    {
      key: 'default',
      label: `Default (${label(listing, listing.defaultAgent)})`,
      checked: detail.agentChoice === null,
      command: command(null),
      confirm,
    },
    ...listing.agents.map((agent) => ({
      key: agent.key,
      label: agent.label,
      checked: detail.agentChoice === agent.key,
      command: command(agent.key),
      confirm,
    })),
  ]
}

export function itemActions(snapshot, item) {
  const { listing } = snapshot
  const detail = detailOf(item)
  const id = item.id
  const actions = []

  actions.push({ key: 'label', label: item.label ? 'Edit Label…' : 'Add Label…', prompt: { type: 'setLabel', id, label: item.label || '' } })
  if (item.label) {
    actions.push({ key: 'clearLabel', label: 'Clear Label', command: { type: 'setLabel', id, label: null } })
  }
  if (detail.canClearAgentBadge) {
    actions.push({ key: 'clearAgentBadge', label: 'Clear Agent Badge', command: { type: 'clearWaiting', id } })
  }
  if (item.kind === 'issue') {
    actions.push({
      key: 'setStatus',
      label: 'Set Status',
      choices: [
        ...listing.issueStatuses.map((status) => ({
          label: status.label,
          command: { type: 'setIssueStatus', id, status: status.key },
        })),
        { label: 'Clear (Auto)', command: { type: 'setIssueStatus', id, status: null } },
      ],
    })
  }
  if (detail.sessionID) {
    actions.push({ key: 'copySession', label: 'Copy Session ID', copy: detail.sessionID })
    actions.push({ key: 'clearSession', label: 'Clear Session', command: { type: 'clearSession', id } })
  }
  if (detail.canClearAuthorBadge) {
    actions.push({ key: 'clearAuthorBadge', label: 'Clear Author Badge', command: { type: 'markAuthorUpdateSeen', id } })
  }
  if (detail.canClearLimit) {
    actions.push({ key: 'clearLimit', label: 'Clear Limit Badge', command: { type: 'clearAgentLimit', id } })
  }
  if (detail.canHandOver) {
    actions.push({
      key: 'handOver',
      label: `Hand over to ${label(listing, listing.failoverAgent)}…`,
      command: { type: 'handOver', id },
    })
  }
  actions.push({ key: 'refresh', label: 'Refresh from GitHub', command: { type: 'refreshItem', id } })
  actions.push({
    key: 'toggleDisabled',
    label: item.isDisabled ? 'Enable' : 'Disable',
    command: { type: 'setDisabled', id, disabled: !item.isDisabled },
  })
  actions.push({
    key: 'remove',
    label: 'Remove from List',
    danger: true,
    confirm: 'Remove this item? Its worktree is deleted from the Mac.',
    command: { type: 'removeItem', id },
  })

  return actions
}
```

- [ ] **Step 4: Run.** `node --test scripts/web-client.test.mjs` → all PASS (existing + new).

- [ ] **Step 5: Commit.**

```bash
git add App/Resources/web/detail.mjs scripts/web-client.test.mjs
git commit --no-verify -m "feat(gateway): add the phone's pane and action rules"
```

---

### Task 4: Phone item screen — panes, agent pane, rebase banner, actions menu

**Files:**
- Modify: `App/Resources/web/app.js` (replace `Detail`, keep `Conversation` but drive it from the pane)
- Modify: `App/Resources/web/app.css`
- Test: `Core/Tests/GatewayKitTests/ClientCommandContractTests.swift`

**Interfaces:**
- Consumes: `detail.mjs` exports (Task 3); `item.detail` (Task 1/2).
- Produces: new `Detail` component; `ActionMenu({ title, entries, onPick })` component reused by Task 5.

- [ ] **Step 1: Extend the contract test** so the new client file and command are checked. In `ClientCommandContractTests.swift`, make `clientSource` concatenate `app.js` and `detail.mjs`:

```swift
private var clientSource: String {
    get throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/web")
        return try ["app.js", "detail.mjs"]
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }
}
```

Add `"agent":"codex"` to the sample JSON in `theClientSendsCommandTypesTheServerCanDecode`. Add:

```swift
@Test func theClientOffersSetAgent() throws {
    #expect(commandTypes(in: try clientSource).contains("setAgent"))
}
```

- [ ] **Step 2: Run.** `cd Core && swift test --filter ClientCommandContractTests` → `theClientOffersSetAgent` FAILS (detail.mjs exists from Task 3 and already sends `setAgent`, so if it passes, that is acceptable; the test then guards against regression). Record the result either way.

- [ ] **Step 3: Rewrite `Detail` in `app.js`.** Import at top: `import { detailOf, availablePanes, activePane, needsSession, agentOptions, itemActions } from '/detail.mjs'` (match the style of the existing `listing.mjs` import).

Replace the body of `Detail` with this structure (keep `run`, `busy`, `elapsed`, `PRIMARY_LABELS`, `Conversation`):

```js
function ActionMenu({ title, entries, onPick, onClose }) {
  return html`
    <div class="menu-backdrop" onClick=${onClose}>
      <div class="menu" onClick=${(event) => event.stopPropagation()}>
        <div class="menu-title">${title}</div>
        ${entries.map(
          (entry) => html`
            <button
              key=${entry.key || entry.label}
              class=${entry.danger ? 'danger' : ''}
              onClick=${() => onPick(entry)}
            >
              ${entry.checked ? '✓ ' : ''}${entry.label}
            </button>
          `
        )}
        <button class="menu-cancel" onClick=${onClose}>Cancel</button>
      </div>
    </div>
  `
}
```

`pickEntry(entry)` shared helper (inside `Detail`, and exported to Task 5 by moving it to module scope taking `{ token, onError, onNotice }`):

```js
async function runEntry(entry, { token, onError, onNotice, after }) {
  if (entry.choices) return { choices: entry.choices }
  if (entry.copy) {
    try {
      await navigator.clipboard.writeText(entry.copy)
      onNotice('Copied.')
    } catch {
      onError('Copy failed. The browser blocked the clipboard.')
    }
    return {}
  }
  if (entry.confirm && !window.confirm(entry.confirm)) return {}
  let command = entry.command
  if (entry.prompt) {
    const text = window.prompt('Label', entry.prompt.label)
    if (text === null) return {}
    command = { ...entry.prompt, label: text.trim() === '' ? null : text.trim() }
  }
  try {
    const result = await sendCommand(token, command)
    if (result.status === 'rejected') onError(result.message || 'The Mac refused that command.')
    else if (result.message) onNotice(result.message)
  } catch (error) {
    onError(String(error.message || error))
  }
  if (after) after()
  return {}
}
```

`Detail` layout, top to bottom:

1. Title and meta (existing).
2. `attentionReason` banner (existing).
3. Rebase banner, from `detailOf(item).rebase`: conflicted → `Rebase paused — N conflict(s). Resolve it on the Mac.`; failed → `Rebase failed: <message>. Dismiss it on the Mac.` Class `banner` with `warn`/`error` modifier. No buttons.
4. Segmented switch: `<div class="segments" role="tablist">` with one button per `availablePanes(item)`; label `claude` → `${detailOf(item).agentLabel}`: use `item.agent?.kind || label from listing.agents by detail.agentKey` + ` Review`, `github` → `GitHub`. State `chosen` (`useState(null)`), `pane = activePane(item, chosen)`. On tap: `setChosen(key)`, and `sendCommand(token, { type: 'setPane', id: item.id, pane: key })`.
5. Run label line: `detail.runLabel` when `pane === 'claude'`.
6. Pane body:
   - `pane === 'github'`: existing summary card, badges with help, branch facts, then `item.url` → `Open on GitHub ↗` link. When `item.url` is null render nothing for the link.
   - `pane === 'claude'`:
     - `paneState` `idle` → note `No session yet.` and a `Start` button: `run({ type: 'startSession', id: item.id, forceFresh: false }, 'start')`. Also on first render of the pane, if `needsSession(item)`, `useEffect` sends the same command once (guard with a ref), as the Mac does on `.task`.
     - `preparing` → `Preparing the worktree…`.
     - `failed` / `unavailable` → `detail.paneMessage` in an error card.
     - `live` → `<${Conversation} .../>` (always shown, no opt-in button).
     - Agent header above the body: current agent label, button `Agent ▾` opening `ActionMenu` with `agentOptions(snapshot, item)`; picking runs `runEntry`.
7. Bottom bar (replace the sheet): `primary` button (existing `primaryCommand`/`PRIMARY_LABELS`, fallback `Fresh session`) and a `•••` button opening `ActionMenu` with `itemActions(snapshot, item)`. For an entry with `choices`, `runEntry` returns `{ choices }`; set a second menu state to show them. `Detail` therefore receives `snapshot` as a new prop; update the `App` call site: `<${Detail} item=${open} snapshot=${snapshot} .../>`.

Delete the old `moreOpen`, `confirmRemove`, `showConversation` state and the `.sheet`/`.more-menu` markup.

`Conversation`: when `sendPrompt` is rejected, `onError` already shows the Mac text, so the "prompting is off" case needs no change.

CSS in `app.css`: add `.segments`, `.segments button`, `.segments .on`, `.menu-backdrop` (fixed, full screen, flex-end, rgba dim), `.menu` (sheet, safe-area bottom padding, max-height 80vh, overflow auto), `.menu button` (full width, 44px min height), `.banner.warn`, `.banner.error`, `.agent-head`. Reuse existing colour variables; follow the file's existing `.sheet`, `.banner` and `.badge` rules for tokens. Remove `.sheet`, `.grabber`, `.sheet-row`, `.more-menu`, `.conv-open` rules that are no longer used.

- [ ] **Step 4: Verify in a browser and with tests.**

```bash
node --test scripts/web-client.test.mjs
cd Core && swift test --filter ClientCommandContractTests
```

Both PASS. Then run the app (`/run` skill or open the project in Xcode), open the gateway URL in a desktop browser at phone width and check each Review Focus item by hand: disabled item, task item, idle item with Start, working item agent switch confirm, rebase banner on a conflicted item, item removed on the Mac while open. Record what you saw in the commit body.

- [ ] **Step 5: Commit.**

```bash
git add App/Resources/web Core/Tests/GatewayKitTests/ClientCommandContractTests.swift
git commit --no-verify -m "feat(gateway): give the phone the Mac's GitHub and agent panes"
```

---

### Task 5: Long-press row menu

**Files:**
- Modify: `App/Resources/web/app.js` (`Row`, `List`, `App`)
- Modify: `App/Resources/web/app.css`

**Interfaces:**
- Consumes: `itemActions`, `ActionMenu`, `runEntry` (Task 4).

- [ ] **Step 1: Implement.** In `Row`, add a long-press: on `onTouchStart` start a 500 ms timer that calls `onMenu(item)`; clear it on `onTouchEnd`, `onTouchMove` and `onTouchCancel`; when it fired, swallow the following click (`firedRef`) so the item does not also open. Add `onContextMenu=${(e) => { e.preventDefault(); onMenu(item) }}` for desktop testing. Add CSS `-webkit-touch-callout: none; user-select: none;` to `.row`.

In `App`, hold `menuItem` state. When set, render `<${ActionMenu} title=${menuItem.title} entries=${itemActions(snapshot, menuItem)} onPick=... onClose=... />` using the same `runEntry` and the same second-level `choices` handling as `Detail`. Pass `onMenu=${setMenuItem}` through `List` to `Row`. Close the menu after a command runs (`after`).

- [ ] **Step 2: Verify.** `node --test scripts/web-client.test.mjs` PASS. In the browser: right-click a row → menu with the same entries as `•••` on that item; tap still opens the item; a touch-hold on a real phone opens the menu without opening the item (check on the phone through `prpilot.masa.gi`, and say so if you could not).

- [ ] **Step 3: Commit.**

```bash
git add App/Resources/web
git commit --no-verify -m "feat(gateway): open the Mac context menu on a long press"
```

---

### Task 6: Full verification

**Files:** none changed unless a failure needs a fix.

- [ ] **Step 1: Run the full Swift suite.** `cd Core && swift test 2>&1 | tail -30`. Expected: all tests pass, count above 964. Three timing tests are known to flake on a clean tree (session drain, two pty release): re-run them alone to confirm, and say so.
- [ ] **Step 2: Run the node suite.** `node --test scripts/web-client.test.mjs`. Expected: all pass.
- [ ] **Step 3: Build the app.** `xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5`. Expected: `BUILD SUCCEEDED`. Format changed Swift files with `gci write --skip-generated -s standard -s default <file>` only if a Go file changed (none expected).
- [ ] **Step 3b: Check the forbidden-command guard.** `grep -n "push\|rebase" Core/Sources/GatewayKit/GatewayCommand.swift` shows only the doc comment.
- [ ] **Step 4: End-to-end on a real phone or phone-width browser** through the running gateway: open one PR, one issue, one task, one disabled item; switch panes; send a prompt; change agent; long-press a row. Report what worked and what did not.
- [ ] **Step 5: Report.** Quote the literal command output for Steps 1–3. Do not bump the version or release; ask the user first.
