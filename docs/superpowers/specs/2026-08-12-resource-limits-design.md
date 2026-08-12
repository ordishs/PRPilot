# Resource Limits

Date: 2026-08-12

## Problem

PRPilot grows without bound as the work item count grows. The machine runs its fan
continuously and swap approaches exhaustion.

### Measurement

The numbers below come from a live sample. PRPilot ran for three minutes. The user
opened eight to ten items, then left the app idle.

PRPilot started one `claude` process for each work item:

```
74821 ppid=74668 rss=546MB 03:21
74948 ppid=74668 rss=612MB 03:19
75032 ppid=74668 rss=541MB 03:18
... 13 processes
claude total: 7.0 GB
```

The count still climbed at sample time. The store holds 36 items, so the loop ends
near 36 processes and approximately 20 GB.

Web views accumulate in parallel:

```
WebContent processes: 22
WebContent total: 2.8 GB
```

Swap sat near exhaustion:

```
vm.swapusage: total = 13312.00M  used = 12912.88M  free = 399.12M
```

Spotlight indexes the managed worktree root:

```
$ mdfind -onlyin ~/Library/Application\ Support/PRPilot/worktrees "go.mod"
/Users/.../worktrees/bsv-blockchain-teranode-pr1491/plans/subtree-lift-audit-notes.md
/Users/.../worktrees/bsv-blockchain-teranode-pr1491/test/chaos/implementation_summary.md
/Users/.../worktrees/bsv-blockchain-teranode-pr1491/test/multinode/harness/harness.go
```

The root holds 49 directories and 11 GB.

PRPilot itself read 0.0% CPU during the sample. Its contribution to the fan is
indirect. It runs through swap pressure, not through direct CPU burn.

### Causes

Four unbounded loops:

- `Core/Sources/AppCore/AppModel.swift:810` — `prewarmClaude()` iterates every
  non-disabled item and starts a Claude session for each, because `autoLoad` is true.
- `App/WebViewCache.swift` — `remove(reviewID:)` runs only when an item leaves the
  list. A web view created for an item lives until then.
- `Core/Sources/AppCore/AppModel.swift:958` — `refreshReviewStates()` refreshes every
  open PR on every poll cycle. At 18 open PRs and a 60 second interval that is
  approximately 22 `gh` launches per minute.
- The managed worktree root accumulates orphaned directories. It holds 49 directories
  for 36 items.

### Non-goal

A cap on the number of PRs or issues in the sidebar. A sidebar row costs almost
nothing. Such a cap would hide real work and would not address any cause above.

## Design

### 1. `SessionBudget`

A new pure type in `AppCore`. It holds no reference to a process, a PTY, or a
`ClaudeSession`.

Input:

- The live sessions, as `(id, lastOpenedAt, ClaudeStatus)`.
- The cap.
- The selected item id.

Output: the ids to evict, oldest first.

Rules:

- Sort the live sessions by `lastOpenedAt`, newest first.
- Every session past the cap becomes an eviction candidate.
- Never evict the selected item.
- Never evict a session in `.working` or `.starting`. Move to the next candidate.
- If every candidate is protected, evict nothing. Stay above the cap.

The cap is a strong target, not a hard ceiling. A long review must never lose its
work to an eviction. This is why the type returns a list instead of enforcing a
number.

### 2. Session eviction in `AppModel`

A new `enforceSessionBudget()` runs at two points:

- After each successful `ensureClaudeSession`.
- On each selection change.

For each id to evict:

- Call `claudeSessions[id]?.terminate()`.
- Remove the entry from `claudeSessions`.
- Leave `claudeSessionID` in the store unchanged.

The last rule makes eviction safe. `ensureClaudeSession` at `AppModel.swift:623`
already resumes a persisted session when its transcript still exists.
`ClaudeLaunchBuilder` already passes `--resume <sessionID>`. A returning item
therefore continues where it stopped.

`prewarmClaude()` at `AppModel.swift:810` stops iterating all items. It walks the
items in recency order and starts sessions until it reaches the cap.

### 3. Web view eviction

`WebViewCache` gains an ordered list of item ids, sorted by last activation, and an
`evict(beyond:keeping:)` call. A web view has no busy state, so the rules are
simpler than for sessions:

- Sort by last activation, newest first.
- Evict everything past the cap.
- Never evict the selected item.

`activate(for:)` records the activation and then calls `evict(beyond:keeping:)`.
That is the only trigger. A view created by `ensure(for:)` but never activated has
loaded nothing, so it costs no WebContent process and needs no eviction.

Eviction reuses the existing `remove(reviewID:)`. That call already stops the load
and invalidates the KVO observation on `estimatedProgress`.

A returning item pays one page load.

### 4. Focused refresh

`refreshReviewStates()` at `AppModel.swift:958` stops refreshing every open PR on
every cycle. The new schedule:

- The selected item refreshes on every cycle.
- Every other item carries a `lastRefreshedAt` timestamp, held in memory.
- Each cycle refreshes at most four other items. It picks the most stale first.

At 18 open PRs this cuts the steady-state rate from approximately 22 `gh` launches
per minute to approximately five.

Accepted trade-off: `notificationsEnabled` is true. A non-selected PR now reaches a
full sweep in about four cycles instead of one. Its "Updated" chip and its
notification lag by that much. Section 5 is the escape hatch.

### 5. Manual refresh command

A `CommandMenu` item, "Refresh All", bound to `⇧⌘R`.

`⌘R` is unavailable. `App/WebPane.swift:17` already binds it to a reload of the
current web page.

The command runs `discoverNow()`, then refreshes every open PR and ignores the
stale thresholds. It reuses the existing `discoveryTask` guard, so a manual run
cannot overlap a scheduled one.

### 6. Worktree hygiene

Two independent pieces.

**Spotlight exclusion.** The managed worktree root becomes `worktrees.noindex`.

Two exclusion methods were tested in a genuinely indexed location:

```
$ mdfind "zqxjprpilotprobe77104"
/Users/ordishs/prpilot-idxtest/plain/probe.txt
/Users/ordishs/prpilot-idxtest/marked/probe.txt
```

The `marked` directory held a `.metadata_never_index` file. Spotlight indexed it
anyway, so that method fails. The `prpilot-idxtest.noindex` directory is absent from
the results, so the directory-name suffix works.

A one-time migration on launch renames the directory and rewrites each item's
`worktreePath`. A `schemaVersion` bump guards it, so it runs once.

**Orphan pruning.** A "Prune Worktrees" command scans the worktree root for
directories with no matching item. It reports the count and the total size, then
deletes on confirmation. The store has 13 orphans today.

### 7. Settings

Two new fields on `Settings`. Both decode through `decodeIfPresent` with a default,
which matches the existing pattern at `Settings.swift:108`:

- `maxLiveClaudeSessions`, default 5
- `maxLiveWebViews`, default 8

Each gets a `Stepper` in `SettingsView`, beside the existing poll interval control.

## Testing

- `SessionBudget`: the cap, the selected-item exemption, the `.working` skip, the
  `.starting` skip, and the all-candidates-protected case.
- Web view LRU ordering: the ordering logic, tested apart from `WKWebView`.
- Focused refresh: the staleness picker, tested as a pure function.
- Migration: a pre-migration store lands on `worktrees.noindex` with rewritten
  paths. A second run changes nothing.
- Orphan detection: a root with known orphans and known live worktrees yields the
  correct orphan set.

## Expected effect

| Cost | Today | After |
|---|---|---|
| Claude sessions | 7.0 GB, heading to ~20 GB | ~2.8 GB |
| Web views | 2.8 GB | ~1.0 GB |
| `gh` launches | ~22/min | ~5/min |
| Spotlight | 11 GB indexed | 0 |

The design frees approximately 6 GB. Swap sat at 12.9 GB of 13.3 GB, so that should
end the swap pressure.

This is a prediction, not a measured result. Verification requires a repeat of the
process sample after implementation.
