# Remote Gateway — Design Spec

- **Date:** 2026-09-16
- **Status:** Implemented — Tasks 1 to 12 of the plan are merged; on-device
  verification outstanding
- **Scope:** Read and control PR Pilot from an iPhone or iPad over Tailscale
- **Revised:** 2026-09-17 — decision 13, the bind scope. The original spec said
  the listener binds loopback only, which made a reverse proxy on another
  tailnet node impossible. See "Lifetime" and "Authentication".
- **Revised:** 2026-09-17 — decisions 15 to 17: the agent conversation, replying
  from the phone, and search, sort and full badges in the list. Decision 16
  reverses decision 10. See "Conversation" and "List screen".
- **Revised:** 2026-09-17 — decision 14, tabs. The four groups became a
  segmented control after use on a phone showed a scrolling list buries the
  group that matters. See "List screen".
- **Revised:** 2026-09-23 — decision 18, the Mac layout. The four attention
  groups became the Mac sidebar sections, pills, search and sorts. "Agent
  finished its review" is no longer a reason: `claudeReviewedAt` never clears,
  so nearly every item sat under `Needs you`. Decision 18 supersedes decisions
  14 and 17. Wire version 2. See "List screen" and "Attention reason".

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
| 13 | Bind scope | Setting, loopback by default, tailnet optional | A reverse proxy on another tailnet node cannot reach a loopback listener. Safe by default, explicit to widen, never a wildcard. Added 2026-09-17 |
| 14 | Group presentation | One tab per group, top segmented control, always opens on Needs you | A scrolling list put the group that matters below the fold on a real phone. Added 2026-09-17 |
| 15 | Agent conversation | Read the transcript on disk, not the terminal screen | The terminal holds only the visible rows, so anything scrolled past is lost. `HandoverNote` already parsed these files. Added 2026-09-17 |
| 16 | Row density | Full badge set on every row, wrapping | **Reverses decision 10.** Chosen knowingly after use: seeing every state without opening an item beat fixed-height rows. Added 2026-09-17 |
| 17 | Search scope | Searching ignores the tabs and returns a flat, group-tagged list | You rarely know which group the item you are hunting for landed in. Added 2026-09-17. Superseded by 18 |
| 18 | List layout | The Mac sidebar: one tab per section, the same pills, search and sorts | The attention groups disagreed with the Mac, and a sticky reason put nearly everything under `Needs you`. One set of rules on both screens. **Supersedes decisions 14 and 17.** Added 2026-09-23 |

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
Settings enables it, on a configured port and one of two bind scopes.

**Bind scope.** Loopback is the default: `127.0.0.1`, so nothing off the Mac
can connect. The alternative is the Tailscale interface, for the case where a
reverse proxy on another tailnet node must reach the gateway — a proxy cannot
reach a loopback listener, so loopback makes that topology impossible.

`TailnetAddress` finds the address by matching an up interface against
`100.64.0.0/10`, the carrier-grade NAT range Tailscale assigns from. Matching
the range rather than an interface name avoids depending on the `tailscale`
binary being installed or on `PATH`.

The scope never widens beyond what the user asked:

- A `.tailnet` scope with Tailscale down falls back to loopback. A gateway
  nobody can reach is a nuisance; one that silently binds something wider
  would be a defect.
- Neither scope ever binds `0.0.0.0`. There is no code path that can.
- A `.tailnet` scope binds that one address, so `127.0.0.1` stops answering.
  This is a deliberate consequence of binding a specific interface.

**Reaching it from a phone.** Two topologies are supported, and the bind scope
picks between them:

| Scope | Front end | Phone reaches |
|---|---|---|
| loopback | `tailscale serve --bg 8776` | `https://<node>.<tailnet>.ts.net` |
| tailnet | nginx on another tailnet node | a hostname of your own, e.g. `https://prpilot.masa.gi` |

The verified local Tailscale version is 1.98.9. `tailscale serve` requires
Serve to be enabled for the tailnet in the admin console; it is not on by
default and the CLI hangs without a clear message when it is off.

A reverse proxy must disable response buffering on `/api/events`. nginx buffers
proxied responses by default, which holds each snapshot until a buffer fills,
so the stream connects and then appears dead.

Settings gains four controls:

- Gateway on or off.
- Port (default 8776).
- Bind scope: "This Mac only" or "Tailnet", with a warning when Tailscale is
  down.
- A read-only, copyable line: the `tailscale serve` command under loopback, or
  the `http://<tailnet-ip>:<port>` proxy target under tailnet.

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
  sections: [GatewaySection]     always all three: myWork, reviewRequests, issues
  listing: GatewayListing        the Mac's pills, sorts and defaults
  warnings: [String]             discovery warnings

GatewaySection
  kind: myWork | reviewRequests | issues
  items: [GatewayItem]           split and sorted by sidebarSections, as on the Mac

GatewayListing
  signalFilters: [GatewayOption]   key, label, help from SignalFilter
  resourceFilters: [GatewayOption] key, label, help from ResourceFilter
  sorts: [GatewayOption]           from SidebarSort
  sort: String                     the Mac's sort, the phone's starting point
  hideParked: Bool                 the Mac's Hide parked, the phone's starting point

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
  signals: [String]              SignalFilter keys, from AppModel.sidebarFacts
  resources: [String]            ResourceFilter keys, from AppModel.sidebarFacts
  isParked: Bool                 isParkedReview, the Hide parked test
  addedAt: Date, statusRank: Int sort keys for Recent and By status

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

### Attention reason

`GatewayKit` owns one pure function, `GatewayAttentionRule.evaluate`. It maps a
work item's state to an optional attention reason plus primary command. The row
and the detail banner show the reason; the sticky button runs the command. It
no longer decides where an item is listed — the Mac sections do that.

Its input is `GatewayItemFacts`, a flat value type of booleans and dates that
`AppCore` builds:

```
GatewayItemFacts
  isDisabled: Bool
  limitMessage: String?        non-nil when the agent stopped on a limit
  awaitsMyResponse: Bool       from WorkItem.awaitsMyResponse(myLogin:)
  hasUnseenAuthorUpdate: Bool
```

`AgentStatus` lives in `AgentKit`, which links SwiftTerm. `GatewayKit` must not
depend on `AgentKit`, or the gateway would drag a terminal emulator into a
module that renders no terminal. `AppCore` flattens `AgentStatus` into these
booleans at the boundary.

Priority order, first match wins:

| Condition | Reason | Primary command |
|---|---|---|
| Agent hit a usage limit | "Agent hit its usage limit" | `clearAgentLimit` |
| Agent finished a turn you have not answered | "Agent is waiting for you" | `clearWaiting` |
| Author pushed unseen commits | "Author pushed new commits" | `markAuthorUpdateSeen` |
| Otherwise | none | none |

A disabled item has no reason, whatever else is true.

Every reason clears when you act on it. The first design also listed "Agent
finished its review", keyed on `claudeReviewedAt`. Nothing clears that field,
so an item the agent reviewed once asked for you forever, and in use nearly
the whole queue sat under `Needs you`. The unanswered turn is already the
`awaitsMyResponse` row, and it clears when you post a review.

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

**`startSession` with `forceFresh` restarts a live session.** `ensureAgentSession`
returns early when a session is already running, so asking it for a fresh one on
a running item did nothing — the one case a user would reach for it. The gateway
routes `forceFresh` through `clearAgentSession` instead, which terminates the
process, archives the transcripts so the old conversation cannot be resumed, and
starts a new session itself. That made a separate `clearSession` button
redundant under a misleading name, so the client no longer offers one.

**`handOver` reports what it did.** A silent success left the user guessing which
agent picked the work up. It now returns an *accepted* result carrying the agent
pair and the fact that a note was written, and the client renders accepted
messages as a notice rather than an error. Its two failure modes are named
separately rather than collapsed: the item already runs on the failover agent —
an account cannot rescue itself — or it has no worktree yet.

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

The operating system enforces the reachability boundary, because the listener
binds one specific address. Under loopback only a local process can connect.
Under the tailnet scope only tailnet peers can. Neither is a wildcard, so no
middleware check can improve on it and none is written.

**A tailnet identity header alone is not sufficient, under either scope.**
Any process that can reach the listener can set an arbitrary request header.
If the gateway trusted `Tailscale-User-Login` by itself, any program on the Mac
— or, under the tailnet scope, any tailnet peer — could forge it and drive the
queue. The proxy injecting the header does not stop a client that bypasses the
proxy and talks to the port directly.

The tailnet scope makes this stronger, not weaker, as a reason: it widens the
set of hosts that can forge a header from "this Mac" to "every device on the
tailnet".

`BearerTokenVerifier` is therefore the default, whatever the probe finds. The
token is a shared secret that a forged header cannot supply. A tailnet header,
when present, is recorded for display and audit only. `TailnetHeaderVerifier`
ships for the case where the listener is later moved behind a socket that only
the proxy can reach, and it is never the default on a network port.

Middleware guards every `/api/*` route with one check: verify the identity.

Step 2 is a protocol, not a fixed mechanism:

```swift
public protocol IdentityVerifier: Sendable {
    func verify(headers: [String: String]) -> GatewayIdentity?
}
```

Two implementations ship, both tested: `TailnetHeaderVerifier(headerName:allowlist:)`
and `BearerTokenVerifier(token:)`. Settings picks which one is wired at
startup. The gateway is therefore not blocked on the open item below, and the
answer changes one line of wiring rather than the middleware.

**Open item.** `tailscale serve --help` on version 1.98.9 does not document the
identity headers it injects. Confirm the header set against a live
`tailscale serve` to decide which verifier is the default.

The app generates the bearer token at first launch, stores it in the Keychain,
and shows it in Settings as a QR code. The client keeps it in `localStorage`
after the first scan and sends it as `Authorization: Bearer`.

The probe result decides only whether the snapshot can also report which
tailnet user is connected. It does not change the authentication mechanism.

The probe is: serve a local echo endpoint through `tailscale serve --bg`,
request it over the `*.ts.net` URL from a second device, and record the
received headers.

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

The list mirrors the Mac sidebar (decision 18). A segmented control under the
header selects one section: `My Work`, `Review Requests`, `Issues`, in the Mac
order. The server splits and sorts the items with the same `sidebarSections`
call the sidebar makes, so an item sits in the same section on both screens.
The view opens on `Review Requests`.

Under the search box sits the Mac filter bar as one sideways-scrolling strip:
the nine signal pills, the three resource pills and `Hide parked`, with the
Mac's labels and help text from `GatewayListing`. The match rule is the Mac's
`sidebarItemMatches`:

- Pills inside one group widen the result; the two groups narrow each other.
- `Hide parked` is an exclusion. It runs first and it wins.
- Pill counts cover every item, whatever is selected, as on the Mac.

Each item carries its signal and resource keys, built by
`AppModel.sidebarFacts(for:)`. The Mac sidebar calls the same function, so a
pill count on the phone always matches the Mac. The `Web` resource asks the
Mac's web view cache through `AppModel.webViewIsLive`.

Search matches the Mac's fields: title, owner/repo, author, head branch, label
and `#number`, case-insensitively. Search and pills narrow every section, and
the tab counts follow them, as the Mac section headers do. When the open tab
comes up empty, the note gives the counts in the other sections.

**Sorting** offers the Mac orders: Recent, By status and By author, each
falling back to newest first. The phone starts from the Mac's sort and Hide
parked, then keeps its own changes: a tap on the phone never rearranges the
Mac sidebar.

A row shows the title, the attention reason in words, then the repository,
number, author, relative age and label, then **the full badge set, wrapping**
(decision 16). Only a disabled row is dimmed.

The list logic lives in `listing.mjs`, a module with no DOM and no imports, so
node can test it. `app.js` renders.

### Conversation

The detail screen can show the agent's conversation, read from its transcript
and refreshed every four seconds while open. It is behind a tap, not loaded
with the item: a transcript dwarfs the queue and is only wanted for the item
being read.

**Why the transcript and not the terminal.** Mirroring the terminal was
originally called the most expensive part of this design, on the grounds that
the pty is fused to an AppKit view. That was wrong in two ways:

- `AppleTerminalView.send(txt:)` writes to the child's stdin, so typing into a
  running agent needs no pty split at all — it is one call.
- `Terminal.getText(start:end:)` would return the rendered screen, so even a
  mirror would not need the byte stream.

The transcript is still the better source: `getText` returns only the visible
rows, so anything the agent wrote before the last scroll is gone, and it dies
with the session. The transcript holds the whole conversation and survives a
restart. `HandoverNote.transcriptURL(for:worktreePath:sessionID:)` and
`HandoverNote.entries(inTranscriptAt:kind:)` already existed for the handover
feature, and already strip tool results and system reminders.

`GET /api/transcript?id=<id>&limit=<n>` returns `GatewayTranscript`. The id
travels as a query parameter because real ids contain `/` and `#`, which break
a path component. `limit` is clamped to 1...500 and defaults to 80.

An item with no transcript returns `available: false` and a `note` saying why —
no worktree, no session yet, or nothing conversational recorded. An empty
conversation and an absent one are different states and read differently.

**Replying is off by default**, behind `Settings.gatewayAllowPrompts`, separate
from the gateway toggle. Reading the queue and driving an agent are different
risks: the agents launch with `--dangerously-skip-permissions`, so whoever
holds the token can otherwise do anything in the user's worktrees. The command
is refused when the setting is off, when no session is live, and when the text
is empty.

### Detail screen

The header carries a back link to the list. Below it:

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

`manifest.json` with `display: standalone` and the `apple-mobile-web-app-capable`
meta tag. No service worker in v1: the client is pull-only, so there is nothing
to receive in the background and no offline requirement.

Icons are generated from the Mac app's own `AppIcon` asset, so the phone, the
browser tab and the Dock all show one mark:

| File | Used for |
|---|---|
| `icon-32.png` | Browser tab favicon |
| `icon-180.png` | `apple-touch-icon`, iOS home screen |
| `icon-192.png` | Manifest icon, and a larger favicon |
| `icon-512.png` | Manifest icon, declared `any` and `maskable` |

`maskable` matters on Android, which crops a non-maskable icon into its own
shape and can clip the artwork.

## Testing

`GatewayKit` is tested against a fake `GatewayBackend`, with no `AppModel`, no
`gh`, and no git:

- `TailnetAddress` accepts every address in `100.64.0.0/10` and rejects
  addresses just outside it, ordinary private ranges, loopback, and malformed
  input.
- `bindAddress(for:)` returns loopback for the loopback scope, and for the
  tailnet scope returns either a `100.64.0.0/10` address or loopback — never a
  LAN address and never `0.0.0.0`.
- Auth middleware rejects a missing or non-allowlisted identity.
- The client declares a title for every `GatewaySectionKind`, in the Mac
  order, and reads only item fields the server sends, checked against the real
  `listing.mjs`.
- Every `GatewayCommand` case maps to the intended backend call.
- A repeated `commandID` returns the cached result and does not call the
  backend a second time.
- `removeItem` is refused when `localChanges` is greater than zero, and
  accepted when it is zero.
- The attention rule assigns the right reason and primary command for each
  state combination in the priority table, including the disabled override,
  and gives no reason to an item with nothing outstanding.
- Snapshot projection is stable: a known `WorkItem` maps to the expected
  `GatewayItem`.
- The SSE stream emits on a snapshot change and stays silent when the hash is
  unchanged.
- The poller stops after the last client disconnects.

`AppCore` gets one test that `AppModel` satisfies `GatewayBackend` end to end
against a real `ReviewStore`.

The client list logic has node tests in `scripts/web-client.test.mjs`, run with
`node --test scripts/web-client.test.mjs`. They cover the pill rule, search,
the three sorts, and the tab and pill counts. The render code in `app.js` has
no automated tests.

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

1. The tailnet identity header set, as described under Authentication. This is
   now cosmetic. Authentication uses the bearer token either way. The answer
   decides only whether the snapshot can display the connected tailnet user.
   Probing it needs `tailscale serve`, which needs Serve enabled for the
   tailnet in the admin console — not the case at the time of writing.

## Future work, explicitly out of scope

- Web Push when an agent stalls. Needs a service worker, a VAPID key pair, and
  subscription storage.
- Binding loopback and the tailnet address at once. Today the tailnet scope
  binds one address, so `127.0.0.1` stops answering while it is selected.
- Git commands from the phone.
- A mirrored terminal, and the PTY split it requires.
- A native iOS client on the same API.
