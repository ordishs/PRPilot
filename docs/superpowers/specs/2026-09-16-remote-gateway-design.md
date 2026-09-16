# Remote Gateway — Design Spec

- **Date:** 2026-09-16
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Scope:** Read and control PR Pilot from an iPhone or iPad over Tailscale

## Summary

PR Pilot runs on one Mac. Claude Code cannot run on iOS or iPadOS. To see and
steer the queue away from the desk, the Mac app exposes a small HTTP gateway.
A responsive web client, reached over Tailscale, renders the queue and sends
commands.

The gateway is a projection over `AppModel`. It adds no domain logic.

## Goals

- Answer "does anything need me?" in one glance on a phone.
- Clear the common blockers with one tap: agent limit, stale session, triage.
- Add no new attack surface beyond the tailnet.
- Leave the Mac app's behaviour unchanged when the gateway is off.

## Non-goals

- No terminal. The agent TUI is not mirrored. See "Rejected: terminal mirroring".
- No git actions. The client cannot rebase, push, or force-push.
- No push notifications in v1. The client is pull-only.
- No multi-user support. One tailnet identity, one queue.
- No native iOS app. See "Rejected: native client".

## Key decisions (decision log)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Client platform | Responsive web app, installed to the home screen | No signing, no TestFlight, no certificate renewal. One client for phone, tablet and any other machine |
| 2 | Remote scope | Monitor and nudge. No terminal | Removes all PTY work. The PTY is fused to an AppKit view today |
| 3 | Push transport | Server-Sent Events | Traffic is one-directional. `EventSource` reconnects with no client library. Plain HTTP proxies cleanly |
| 4 | Socket.IO | Rejected | No Socket.IO server exists for Swift. Its features solve problems this system does not have |
| 5 | Server library | Hummingbird 2 | SwiftNIO-based, small, Swift 6 concurrency native. Vapor brings far more than a single-user gateway needs |
| 6 | Payload shape | Full snapshot on every change | A realistic queue is a few kilobytes. Deltas would add reconciliation bugs to save bandwidth that is not scarce |
| 7 | Command routing | One `POST /api/command` with a `Codable` enum | The switch is exhaustive, so the compiler catches an unhandled command |
| 8 | Change detection | 1 Hz coalescing poller with a snapshot hash | `AppModel` needs no changes. The stream cannot miss an update |
| 9 | Alerts | Pull-only in v1 | No service worker, no VAPID keys, no subscription storage. Push can be added later without an API change |
| 10 | List layout | Grouped by attention reason, no badges in the list | The phone question is "is anything stuck?", not "reproduce my sidebar" |
| 11 | Detail layout | Sticky primary action, secondary commands in a sheet | The one-tap fix must not require a scroll |
| 12 | Client framework | Preact and `htm`, vendored, no build step | Keyed diffing keeps scroll, focus and sheet state alive across 1 Hz snapshot pushes |

## Architecture

### Module boundary

A new package module, `GatewayKit`, at `Core/Sources/GatewayKit`. It depends on
`PRPilotModels` and Hummingbird only. It must not depend on `AppCore`.

`GatewayKit` declares the contract it needs:

```swift
@MainActor public protocol GatewayBackend: AnyObject {
    func snapshot() -> GatewaySnapshot
    func perform(_ command: GatewayCommand) async -> GatewayCommandResult
}
```

`AppCore` adds `extension AppModel: GatewayBackend`. The dependency flows
`AppCore → GatewayKit` and never the reverse. `GatewayKit` is therefore
testable against a fake backend, with no `AppModel`, no `gh`, and no git.

Add to `Core/Package.swift`:

- A `GatewayKit` library product and target.
- A dependency on `https://github.com/hummingbird-project/hummingbird`, from 2.0.0.
- A `GatewayKitTests` test target.
- `GatewayKit` added to the `AppCore` target dependencies.

Add `GatewayKit` to the `PRPilot` app target in `project.yml`.

### Concurrency

`AppModel` is `@MainActor @Observable` (`Core/Sources/AppCore/AppModel.swift:17`).
Hummingbird handlers run on NIO event loops. Every handler hops to the main
actor to read a snapshot or run a command.

Snapshots are small value types. Commands are rare. The hop costs nothing
measurable.

### Change detection

`@Observable` tracking through `withObservationTracking` is one-shot. It is
awkward to drive a long-lived stream, and a missed re-registration silently
stalls the client.

Use a coalescing poller instead. A main-actor task ticks at 1 Hz. It builds a
snapshot, hashes it, and emits an SSE event only when the hash changes. The
ticker starts when the first client connects and stops when the last one
disconnects.

Trade-off: up to one second of latency, and one wake-up per second while a
client is connected. In exchange, the poller needs no change to `AppModel`, and
the stream cannot miss an update. The only edit the gateway makes inside
`AppCore` is the visibility promotion recorded under "Backing methods in
`AppModel`".

### Lifetime

`GatewayService` is owned by `AppDelegate`. It starts with the app when
Settings enables it. It binds to `127.0.0.1` on a configured port. Nothing
listens on a routable interface.

`tailscale serve` fronts the listener and terminates TLS. The verified local
Tailscale version is 1.98.9. The expected command is:

```
tailscale serve --bg 8776
```

Settings gains three controls:

- Gateway on or off.
- Port (default 8776).
- A read-only display of the `tailscale serve` command and the resulting
  `*.ts.net` URL, with a copy button.

## API

### Routes

| Route | Purpose |
|---|---|
| `GET /` and `/assets/*` | Static client, served from the app bundle |
| `GET /api/snapshot` | Full state, one JSON document |
| `GET /api/events` | SSE stream. First event is a full snapshot, then a snapshot per change |
| `POST /api/command` | Every command |
| `GET /api/health` | Port and app version, for checking the tunnel |

### Wire types

`GatewaySnapshot` and `GatewayCommand` are `Codable` value types in
`GatewayKit`. They are a projection, not the internal model. An internal
refactor must not break a phone that is hard to update.

```
GatewaySnapshot
  generatedAt: Date
  appVersion: String
  login: String?                 the gh login the Mac is using
  groups: [GatewayGroup]         ordered: needsYou, running, queued, idle
  warnings: [String]             discovery warnings

GatewayGroup
  kind: needsYou | running | queued | idle
  items: [GatewayItem]

GatewayItem
  id, kind (pr | issue), owner, repo, number, url
  title, author, headBranch, baseBranch
  attentionReason: GatewayAttentionReason?    one sentence, server-rendered
  agent: GatewayAgent?
  badges: [GatewayBadge]         full set, shown only on the detail screen
  issueStatus: String?
  label: String?
  isDisabled: Bool
  ahead: Int, behind: Int, localChanges: Int
  lastActivityAt: Date?
  primaryCommand: GatewayCommand?             drives the sticky button

GatewayAgent
  kind: String                   claude | codex | pi
  status: String
  verdict: String?               last verdict text from the transcript
  elapsedSeconds: Int?
  tokens: Int?

GatewayBadge
  text: String
  tone: green | orange | red | blue | grey
  help: String                   the same help text the Mac badge carries
```

### Attention reason and grouping

`GatewayKit` owns one pure function. It maps a work item's state to a group and
an optional attention reason plus primary command. This is the rule the whole
list layout depends on, so it is pure, total, and heavily tested.

Priority order, first match wins:

| Condition | Group | Reason | Primary command |
|---|---|---|---|
| Agent hit a usage limit | needsYou | "Agent hit its usage limit" | `clearAgentLimit` |
| Agent is waiting for input | needsYou | "Agent is waiting for you" | `clearWaiting` |
| Agent finished with a verdict | needsYou | "Agent finished its review" | none — the verdict is the payload, and you read it on the detail screen |
| Author pushed unseen commits | needsYou | "Author pushed new commits" | `markAuthorUpdateSeen` |
| Agent session is live | running | none | none |
| Item is in the session queue | queued | none | none |
| Otherwise | idle | none | none |

A disabled item is always `idle`, whatever else is true.

### Commands

`GatewayCommand` is an enum discriminated by `type`. Adding a command is one
case, not a new route.

- **Safe:** `refreshAll`, `refreshItem(id)`, `markAuthorUpdateSeen(id)`,
  `clearWaiting(id)`, `setPane(id, pane)`
- **Session:** `startSession(id, forceFresh)`, `clearSession(id)`,
  `clearAgentLimit(id)`, `handOver(id)`
- **Triage:** `addPR(url)`, `addIssue(url)`, `setIssueStatus(id, status)`,
  `setLabel(id, label)`, `setDisabled(id, disabled)`, `removeItem(id)`

Git actions are absent by construction. There is no enum case for `push`,
`rebase`, `continueRebase`, or `abortRebase`, so no request can reach them.

A command response is `GatewayCommandResult`: an accepted or rejected status, a
message, and the snapshot taken after the command completed.

### Backing methods in `AppModel`

Every command maps to an existing `AppModel` method. The mapping was verified
against the current source.

| Command | `AppModel` method |
|---|---|
| `refreshAll` | `refreshAllNow()` |
| `refreshItem` | `refreshReviewState(for:)` **— see visibility change below** |
| `markAuthorUpdateSeen` | `markAuthorUpdateSeen(id:)` |
| `clearWaiting` | `clearWaiting(id:)` |
| `setPane` | `setPane(_:for:)` |
| `startSession` | `ensureAgentSession(for:forceFresh:)` |
| `clearSession` | `clearAgentSession(for:)` |
| `clearAgentLimit` | `clearAgentLimit(for:)` |
| `handOver` | `handOverToFailoverAgent(for:)` |
| `addPR` | `addPR(urlString:)` |
| `addIssue` | `addIssue(urlString:)` |
| `setIssueStatus` | `setIssueStatus(_:for:)` |
| `setLabel` | `setLabel(_:for:)` |
| `setDisabled` | `setReviewDisabled(_:for:)` |
| `removeItem` | `removeReview(id:)` |

**Required visibility change.** `refreshReviewState(for:)`
(`Core/Sources/AppCore/AppModel.swift:1737`) and
`refreshWorktreeCleanliness(for:)`
(`Core/Sources/AppCore/AppModel.swift:1699`) are currently internal. Promote
both to `public` so `refreshItem` can drive a pull-to-refresh on the detail
screen. This is the only change the gateway requires inside `AppCore`. If that
promotion is unwanted, drop `refreshItem` and keep `refreshAll` only; nothing
else in the design depends on it.

### `removeItem` guard

`AppModel.removeReview` deletes the worktree directory from disk
(`Core/Sources/AppCore/AppModel.swift:534`). It preserves a registered clone,
but it removes a managed worktree outright, including uncommitted work.

The gateway therefore rejects `removeItem` when `localChanges` for that item is
greater than zero. The response explains that the worktree is dirty and that
the item must be removed at the Mac. The client also requires a two-step
confirm before it sends the command at all.

### Authentication

Middleware guards every `/api/*` route:

1. Reject any request whose peer address is not loopback. Only the
   `tailscale serve` proxy can reach the listener.
2. Require a tailnet identity, and check it against an allowlist in Settings.

**Open item, both branches specified.** `tailscale serve --help` on version
1.98.9 does not document the identity headers it injects. The header set must
be confirmed against a live `tailscale serve` before step 2 is implemented.

- **If the proxy injects an identity header:** read it, and compare the login
  against the Settings allowlist, which defaults to this node's own tailnet
  login.
- **If it does not:** fall back to a bearer token. The app generates it at
  first launch, stores it in the Keychain, and shows it in Settings as a QR
  code. The client stores it in `localStorage` after the first scan and sends
  it as `Authorization: Bearer`.

Either branch satisfies the same middleware interface, so the rest of the
design is unaffected. The probe is: serve a local echo endpoint through
`tailscale serve --bg`, request it over the `*.ts.net` URL from a second
device, and record the received headers.

`tailscale funnel` must never be used. It exposes the listener to the public
internet.

### Idempotency

Every command carries a client-generated `commandID`. The server keeps the last
64 IDs with their results. A retry after a tunnel drop returns the original
result. It does not add the same PR twice or start a second session.

## Client

### Delivery

No build step and no `npm`. The client is `index.html`, `app.js`, `app.css`,
`manifest.json`, and an icon. All are bundled as app resources and served by
Hummingbird from `/`.

Dependencies are vendored and committed, never fetched from a CDN. The phone
reaches the Mac over a tunnel. A CDN reference would fail whenever you are off
the internet but still on the tailnet.

### Rendering

Preact and `htm`, vendored as ES modules, about 12 KB together.

The reason is keyed diffing, not ceremony. SSE pushes a full snapshot on every
change. A plain `innerHTML` re-render would lose scroll position, close an open
sheet, and drop focus from the "Add PR" field up to once a second. Keyed
diffing makes a snapshot push a no-op for untouched rows.

### List screen

Rows are grouped under `Needs you`, `Running`, `Queued`, and `Idle`, in that
order. A group header shows its count. An empty group is hidden.

A row shows the title, the attention reason in words, and the repository,
number and relative time. It carries no badges. A row with no attention reason
shows the repository line only.

### Detail screen

The header carries a back link to the group. Below it:

1. Title, repository, number, author, head branch.
2. The attention banner, toned to the reason.
3. The agent card: kind, elapsed time, token count, and the last verdict text.
4. The full badge set, matching the Mac badges from `App/ContentView.swift:568`.
5. PR facts: base branch, ahead and behind counts, local change count.

A sheet is pinned to the bottom. It holds the primary command as a full-width
button, then `Fresh session`, `Hand over`, and a `•••` button. The `•••` sheet
holds `Refresh`, `Set label`, `Set status`, `Disable`, and `Remove`.

An item with no primary command shows `Fresh session` as the full-width button.

### State and commands

Client state is the last snapshot plus local UI state: the open item, the sheet
state, and scroll position. Nothing is derived and cached.

A command button disables itself, sends `POST /api/command` with a fresh
`commandID`, and applies the snapshot in the response. There is no optimistic
update. `startSession` takes real time on the Mac, and a guess that the SSE
stream later contradicts is worse than a spinner.

### Connection state

`EventSource` reconnects on its own. While the stream is down, the client shows
a persistent bar and dims every command button. On reconnect the first event is
a full snapshot, so there is nothing to reconcile.

### Home screen install

`manifest.json` with `display: standalone`, an `apple-touch-icon`, and the
`apple-mobile-web-app-capable` meta tag. No service worker in v1. The client is
pull-only, so there is no push to receive and no offline requirement.

## Testing

`GatewayKit` is tested against a fake `GatewayBackend`, with no `AppModel`, no
`gh`, and no git:

- Auth middleware rejects a non-loopback peer.
- Auth middleware rejects a missing or non-allowlisted identity.
- Every `GatewayCommand` case maps to the intended backend call.
- A repeated `commandID` returns the cached result and does not call the
  backend a second time.
- `removeItem` is refused when `localChanges` is greater than zero, and
  accepted when it is zero.
- The grouping rule assigns the right group, reason, and primary command for
  each state combination in the priority table, including the disabled
  override.
- Snapshot projection is stable: a known `WorkItem` maps to the expected
  `GatewayItem`.
- The SSE stream emits on a snapshot change and stays silent when the hash is
  unchanged.
- The poller stops after the last client disconnects.

`AppCore` gets one test that `AppModel` satisfies `GatewayBackend` end to end
against a real `ReviewStore`.

**Stated gap:** the client gets no automated tests. It is a render function
over a snapshot. Test infrastructure would cost more than the bugs it would
catch at this size. This is a deliberate choice, recorded so it is not mistaken
for an oversight.

## Rejected alternatives

### Native Swift client

A native client adds provisioning profiles, signing, TestFlight, and
certificate renewal. It would win on APNs push, iPad hardware keyboard
handling, Shortcuts, and widgets. None of those are in scope for v1.

The HTTP API is identical either way, so a later native client reuses all the
server work. Nothing here is wasted if that decision changes.

### Terminal mirroring

`AgentSession` owns a SwiftTerm `LocalProcessTerminalView`
(`Core/Sources/AgentKit/AgentSession.swift:11`). The PTY bytes and the renderer
are fused in one AppKit view. A mirrored terminal needs the PTY split out,
fanned to remote clients, and fed remote keystrokes.

That is the most expensive item in the whole idea, and it is identical work for
a native client or a web client. Dropping it removes all of it.

### Socket.IO

No Socket.IO server exists for Swift. `socket.io-client-swift` is a client
only. Using the protocol would mean implementing the Engine.IO handshake,
packet framing, and upgrade negotiation by hand.

Its features — rooms, namespaces, long-polling fallback — solve problems that a
single user with a single server does not have.

### WebSocket

A WebSocket would work. Its duplex channel would go unused, because the Mac
pushes state and the phone posts commands. SSE gives automatic reconnection and
`Last-Event-ID` resumption with no client library.

If a live terminal ever enters scope, a WebSocket route is added beside the SSE
route. Nothing here blocks that.

## Open items

1. The tailnet identity header set, as described under Authentication. Both
   branches are fully specified, so implementation is not blocked on the
   answer. Resolve it before writing the middleware.

## Future work, explicitly out of scope

- Web Push when an agent stalls. Needs a service worker, a VAPID key pair, and
  subscription storage.
- Git commands from the phone.
- A mirrored terminal, and the PTY split it requires.
- A native iOS client on the same API.
