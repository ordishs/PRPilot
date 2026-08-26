# codex as a Third Agent Backend

**Date:** 2026-08-26
**Status:** Approved (transcript discovery: option A)

## Problem

PR Pilot drives two agents, Claude Code and pi. A Claude usage limit blocks the whole
account two or three times a week, and the team also holds a codex account. Today a blocked
Claude leaves no way to carry on inside PR Pilot.

The pi work left a backend protocol behind, so a third agent looks like a small addition.
It is not, because codex breaks the one assumption every part of that protocol rests on.

## Goals

- Run codex in a PR Pilot pane, with the same worktree preparation, status dot and prep log.
- Choose codex per work item, or as the global default.
- Keep a session per agent per item, so flipping an item between agents resumes each
  conversation.
- Leave Claude Code and pi behaviour unchanged.

## Non-Goals (YAGNI)

- A per-item codex model or provider choice. Both go in `codexLaunchArgs`, as for pi.

## Verified mechanics

Everything below was confirmed by running codex 0.133.0 on this machine.

### codex does not key transcripts by working directory

This is the finding that shapes the design.

| | Claude Code | pi | codex |
|---|---|---|---|
| Transcript root | `~/.claude/projects/<encoded cwd>` | `~/.pi/agent/sessions/<encoded cwd>` | `~/.codex/sessions/YYYY/MM/DD` |
| Keyed by cwd | yes | yes | **no** |
| File name | `<uuid>.jsonl` | `<ts>_<uuid>.jsonl` | `rollout-<ts>-<uuid>.jsonl` |
| Caller-supplied ID | `--session-id` | `--session-id` | **none** |
| Resume | `--resume <id>` | `--session <id>` | `resume <id>` (subcommand) |
| Turn complete | `stop_reason == end_turn` | `stopReason == stop` | `event_msg`/`task_complete` |
| Assistant text | `type:assistant` | `message.role:assistant` | `event_msg`/`agent_message` |

codex writes every session of every project into one date-partitioned tree and records the
working directory inside the file, on line 1:

```json
{"timestamp":"2026-08-26T12:08:18Z","type":"session_meta",
 "payload":{"id":"01a03df8-…","cwd":"/private/tmp/…/codexrepo","originator":"codex_exec"}}
```

Three consequences, each a real defect if ignored:

1. `TranscriptWatcher` watches one flat directory with a single `DispatchSource`. It would
   never see a file created in a nested day directory.
2. `AgentTranscriptPath.latestSessionID` would return an unrelated project's session, and
   PR Pilot would resume a stranger's conversation in this worktree.
3. `archiveTranscripts` moves every `.jsonl` in the directory. Pointed at
   `~/.codex/sessions/YYYY/MM/DD` it would archive every codex session started that day,
   across every project. That is destructive, so the protocol must change first.

### codex assigns the session ID itself

There is no `--session-id`. The ID has to come from codex.

`codex resume` takes the ID as a positional argument, and its own help says the picker is
the default "picker by default; use --last to continue the most recent", with
`[SESSION_ID]` documented as "Conversation/session id (UUID) or thread name. UUIDs take
precedence if it parses."

**Partly unproven.** Read from `--help`, not demonstrated. Driven from a script,
`codex resume <id>` needs a terminal (`Error: stdin is not a terminal`), and given a pty it
does not exit within 25 seconds — which is equally consistent with a resumed session and
with a picker waiting for a keypress. Nothing available here separates the two.

This is the same shape of unknown the pi spec carried for Shift+Return, and it carries the
same consequence if wrong: a pane waiting for ever on a keypress. It is the first thing the
end-to-end step must check. PR Pilot only ever resumes an ID whose transcript it has just
confirmed exists, so the unknown-ID case does not arise in normal use.

PR Pilot already has the mechanism. `TranscriptWatcher.onSessionFile` reports the ID of
whichever transcript it attaches to, and `SessionAdoption` decides when to persist it. That
path exists because `/clear` inside Claude Code moves a session to a new ID. codex simply
uses it from the first line rather than the hundredth.

Its `transcriptDirectoryIsShared` guard is computed per worktree path, not per directory, so
it stays correct once the watcher filters candidates by worktree.

### codex needs directory trust, and refuses non-repositories

```
$ codex exec -s read-only '…'          # in a plain temp directory
Not inside a trusted directory and --skip-git-repo-check was not specified.
```

Trust comes from `~/.codex/config.toml`:

```toml
[projects."/Users/ordishs"]
trust_level = "trusted"
```

A blanket entry for the home directory covers PR Pilot's managed worktree root at
`~/Library/Application Support/PRPilot/worktrees.noindex/…`. Managed worktrees are real git
worktrees, so the repository check passes. A machine without that entry fails at launch.
This is a documented prerequisite and a Settings hint, not code.

### codex is an interpreted script

```
$ file $(command -v codex)
… a /usr/bin/env node script text executable
```

Same shape as pi, under the same nvm installation, so `prependsExecutableDirectoryToPath`
is `true` for the same reason.

Measured, not assumed: on this machine codex launches correctly *without* the fix, because
`.zprofile` now exports the nvm PATH eagerly — the robustness improvement the pi spec
suggested was adopted.

```
$ env -i /bin/zsh -l -c "exec …/bin/codex --version"     # no fix
codex-cli 0.133.0                                        # exit 0
```

So the flag is defensive here rather than load-bearing. It stays true for two reasons: a
machine that sets its version-manager PATH only in `.zshrc` still needs it, and it pins the
`node` beside the exact binary that was resolved.

### codex reports limits as structured data

Every `token_count` event carries a rate-limit block:

```json
{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":10080,
 "resets_at":1786206068},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},
 "spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}
```

So codex needs no phrase matching. `LimitStop` exists because Anthropic states a Claude
limit only in prose; codex names it in a field.

**Unverified:** no local codex session is blocked, so there is no captured fixture of a
non-null `rate_limit_reached_type`. The backend reads the field by name and the tests use a
synthesised line. If the field is populated differently in practice, the badge stays silent
— the same failure mode `LimitStop` already documents for a reworded Claude message.

## Architecture

### Transcript discovery moves into the backend (option A)

`AgentBackend` loses `transcriptDirectory(forWorktreePath:) -> URL` and gains three members:

```swift
/// Directories that can hold this agent's transcripts for one worktree.
func transcriptDirectories(forWorktreePath path: String) -> [URL]

/// Whether one transcript file belongs to this worktree.
func transcript(at url: URL, belongsToWorktreePath path: String) -> Bool

/// Whether the app may choose the session ID at launch.
var acceptsAssignedSessionID: Bool { get }
```

A protocol extension defaults `transcript(at:belongsToWorktreePath:)` to `true` and
`acceptsAssignedSessionID` to `true`. Claude Code and pi therefore take no new code: their
directory already encodes the worktree, so every file in it belongs to it.

codex overrides all three. Its directories are today's and yesterday's day directory, which
covers a session that crosses midnight. Membership reads `session_meta.payload.cwd` from
line 1.

`AgentTranscriptPath` applies the filter in `latestSessionID`, `transcriptExists` and
`archiveTranscripts`, so the destructive case in consequence 3 above cannot happen: a codex
archive moves only the files whose `cwd` is this worktree.

`TranscriptWatcher` holds one `DispatchSource` per candidate directory and picks the newest
belonging transcript across all of them. Membership is memoised by path, because line 1
never changes and a rescan runs on every write event. A convenience initialiser keeps the
existing single-directory call shape, so no existing test changes.

Losing a day directory from the candidate list at midnight cannot detach a live tail. The
file source holds its own descriptor, and a rescan that finds no candidate returns without
touching it.

### Launch and resume

| | fresh | resume |
|---|---|---|
| Claude Code | `--name <n> --session-id <id> [prompt]` | `--name <n> --resume <id>` |
| pi | `--name <n> --session-id <id> [prompt]` | `--name <n> --session <id>` |
| codex | `[prompt]` | `resume <id>` |

codex has no `--name`. `resume` is a subcommand, so it must be the first non-option token.
`AgentLaunchBuilder` places the per-item flags and the user's extra arguments before the
backend's arguments, which is valid for codex only while those are options rather than
positional words. That matches how both existing agents are configured.

`ensureAgentSession` must not persist an invented ID for a backend that cannot accept one.
For codex a fresh launch stores no ID, and `SessionAdoption` writes the real one through as
soon as the watcher attaches. A stored codex ID resumes exactly as the other two do.

### Parsing

`CodexBackend.parse`:

- `event_msg`/`agent_message` supplies the snippet, truncated to 80 characters.
- `event_msg`/`task_complete` sets `turnCompleted`.
- `event_msg`/`token_count` sets `limitMessage` when `rate_limit_reached_type` is non-null
  or `spend_control_reached` is true.
- Every other timestamped line is liveness only, exactly as pi treats a user turn.
- `workflowPending` is always false. codex has no `Workflow` concept.

## Data model

Additive, so no schema version bump — `ReviewStore` decodes every field with
`decodeIfPresent`.

- `AgentKind` gains `.codex`, display name "Codex", executable `codex`.
- `WorkItem` gains `codexSessionID`, reached through the existing `sessionID(for:)` pair.
- `Settings` gains `codexPath`, `codexLaunchArgs`, `codexEnv`,
  `codexReviewPromptTemplate`, `codexIssuePromptTemplate`.

The prompt template defaults are prose rather than slash commands, as for pi: codex has no
`/review`.

## UI

The detail pane's agent picker is driven by `AgentKind.allCases`, so codex appears with no
change. Settings ▸ Tools gains a `codex` path row and arguments and environment rows;
Settings ▸ Prompts gains the two codex templates.

## Order of work

1. Transcript discovery protocol change. Claude Code and pi unchanged, suite green.
2. `CodexBackend` and its tests.
3. `AgentKind`, `WorkItem` and `Settings` fields; the no-assigned-ID launch path.
4. Settings rows.
5. Failover: the handover note, the auto-or-manual setting, and the switch.
6. The usage gauge: the reading, the badge and the warning.
7. End-to-end against a live codex session in a real worktree. Three things to confirm, all
   of which need a person at the keyboard:
   - a fresh launch draws codex's TUI in SwiftTerm and the status dot moves working →
     awaiting input;
   - a resume opens the conversation rather than the session picker (see above);
   - Shift+Return behaves, as it does for pi.

Step 1 is a refactor with no user-visible change. Its proof is the unchanged suite.

## Testing

New tests:

- **`CodexBackendTests`** — day-directory resolution across a month boundary; session ID
  parsed out of a real `rollout-…` name; `cwd` membership accepted and rejected against real
  `session_meta` lines; launch arguments for fresh and resume, asserting `resume` leads;
  `parse` over real codex lines for snippet, `task_complete`, liveness and a synthesised
  limit line.
- **`AgentTranscriptPathTests`** — a codex directory holding two projects' transcripts:
  `latestSessionID` returns this worktree's, and `archiveTranscripts` moves only its files
  and leaves the other project's alone.
- **`TranscriptWatcherTests`** — a watcher over two candidate directories attaches to the
  newest belonging file and ignores a newer non-belonging one.
- **`WorkItemTests`** — a store JSON captured before this change decodes with
  `codexSessionID == nil` and every existing ID preserved.

Baseline before this work: 672 tests, one intermittent failure,
`terminateReleasesThePtyWhenAGrandchildInheritsIt`, which passes when run alone. Confirm it
against a clean tree before reading it as a regression.

## Failover on a limit

Approved after the first draft: a handover note, and auto-or-manual as a setting.

### Why a note rather than a pointer

The `/import` skill the original suggestion mentioned does not exist — not in `~/.claude`,
not in `~/.codex`, and `~/.codex/skills` is empty. PR Pilot writes the note itself.

That is the right owner regardless of what upstream ships. Asking a blocked agent to
summarise its own work costs exactly the allowance it has just run out of. PR Pilot already
tails the transcript, so it can render the note with no model call — which is what makes it
work at the moment it is needed.

### What the note contains

`HANDOVER.md`, at the root of the worktree. A fixed name, so a second handover overwrites the
first rather than littering the branch.

- Which agent it came from, which it is going to, and that PR Pilot wrote it. The receiving
  agent must not read it as the previous agent's own words.
- The work: title, number, URL, repository, branch, base.
- Why the agent changed, quoting the limit message verbatim, including any reset time.
- An instruction to check the working tree, because the previous agent may have left edits
  the conversation never mentions.
- The transcript's path, so the receiving agent can read further back itself.
- The conversation, per turn, attributed to the agent that wrote it.

### Which turns are carried

Not simply the tail. Running the renderer against a real 56-turn Claude Code transcript is
what showed why: the last twelve turns were all short assistant preambles, with no user turn
among them at all. A note built from that would tell the receiving agent what the previous
agent had been *saying* and nothing about what it had been *asked*.

So the window is the last twelve turns, plus two turns that carry intent wherever they sit:
the first user turn, which is the task as originally stated, and the most recent one, which is
what the previous agent was actually working on. Gaps are marked, so two distant turns are
never read as consecutive. Each turn is capped at 1500 characters.

### How the note reaches the new agent

`WorkItem.pendingHandoverPath` is set by the switch and consumed by the launch that sends it.
`LaunchPrompt` prepends a pointer sentence to the rendered template, so all three agents carry
it with no per-backend code. Prepended rather than appended: an agent told to "review the pull
request" first will start over before it reaches the note.

Two consequences worth stating:

- The target starts a **fresh** session rather than resuming its own older conversation for
  this item. A resume sends no prompt at all, so the note would never be read — and an
  unrelated earlier thread is the wrong place to continue this work. No transcript is deleted
  or archived; the old conversations stay on disk.
- A blank prompt template still sends the pointer. Otherwise a user who deliberately launches
  with no prompt would silently lose the handover.

### The setting

`Settings.agentFailover` is `.manual` or `.automatic`, defaulting to **manual**.
`Settings.failoverAgent` names the target, defaulting to codex.

Manual offers the switch in the agent menu of a blocked item. Automatic fires once per block,
off the same guard as the limit notification, so a status recomputed every second cannot
switch an item repeatedly.

Manual is the default deliberately. A switch hands a half-finished worktree to an agent with
a different sandbox and approval model, unattended.

An item already running the failover agent is never switched — one account cannot rescue
itself — and neither is an item that is merely idle or working. Only a limit offers the move.

A note that cannot be written does not stop the switch: losing the summary is bad, leaving the
item stuck on a blocked agent is worse. The failure goes to the prep log.

## The usage gauge

A limit stop is only ever discovered after the work has already stopped. codex reports what it
has spent on *every* turn, so the same telemetry read one field wider gives a warning while the
agent is still running.

### What is read

`AgentUsage` carries the percentage, the window it applies to, the reset time, the agent that
reported it, and when PR Pilot read it. All five come off the `primary` block of a
`token_count` event:

```json
"rate_limits":{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":10080,
  "resets_at":1786206068},"secondary":null,...}
```

Only `primary` is read. codex reports a `secondary` window too, null in every session read
here, and guessing at its meaning would put a wrong number in front of the user.

`readAt` comes from the transcript line's own timestamp rather than the clock, so replaying a
transcript on attach does not make an old reading look fresh.

### What is shown

A badge on the sidebar row, but only once the figure has reached the threshold. Below it the
percentage is noise, and a row carrying a badge per agent per item would drown the states that
need acting on. It turns from orange to pink at 99%.

The displayed percentage always rounds **down**, so an agent still working never reads as 100%.
A figure outside 0–100 is clamped — nothing observed reports one, and a "-3%" badge would read
as a bug in PR Pilot rather than in codex.

Its tooltip names the agent, the window and the reset time. The percentage alone does not tell
the user whether they have an hour or a week.

### Staleness

A reading is dropped once its own window has passed `resets_at`, and in any case after twelve
hours. A stale percentage is worse than none: it would invite a handover on the strength of a
figure that no longer holds. The value stays on the item — only the display drops it — so a
session that starts reporting again replaces it rather than filling a hole.

### The warning

One notification per crossing of `Settings.usageWarningPercent`, default 90, adjustable from 50
to 99. It fires on the crossing and not on the state: every codex turn reports usage, so a
session sitting at 95% would otherwise alert on every turn it took. A window that resets earns
a fresh warning next time round.

The body names the failover agent, but only when there is one to name — an item already running
it has nowhere to go.

### Why 90

On a weekly window 10% is most of a day's work: enough to finish the turn in hand, hand the item
over, or raise the limit. Lower and the warning becomes noise; higher and it arrives too late to
act on.

### What it does not do

The gauge does not switch anything. Automatic failover stays tied to an actual block, because
10% of a weekly allowance is a lot of work to abandon on a prediction. Handing over early is a
click, from the same menu.

### A race the gauge exposed

Adding the usage writer made an existing hazard fire constantly, and the suite started failing
about three runs in four.

One transcript line can start four separate writes to the same item: the limit badge, the
turn-completion stamps, an adopted session ID, and now the usage reading. Each read the item,
changed its own field, and upserted the whole record from a detached task. Two running
concurrently means the later write puts the earlier one's field back as it was. Which field is
lost depends on scheduling, so the symptom was a badge or a stamp that intermittently failed to
stick — and the failures contradicted each other run to run.

The hazard predates this work: `persistAdoptedSession` already carried a comment about
re-reading the item inside its task rather than persisting a copy. Re-reading narrows the
window but does not close it, because both tasks can still read before either writes. Usage
arrives on every codex turn, which is what turned a rare race into a reliable one.

All four now go through `enqueueItemEdit`, a single chained task, so each edit sees the previous
one's result. Ordering matters as much as atomicity: events arrive in transcript order, and a
limit cleared by a later line must not be re-applied by an earlier line's write landing second.

`waitForPendingItemEdits()` lets a test await the chain. The affected tests had been sleeping
300 milliseconds and hoping, which is the same race in the test harness; they now wait for the
work, and notification assertions poll the stub instead of guessing a duration.

### Still to do

codex → Claude works today by setting `failoverAgent` to Claude Code, but it detects the block
through `LimitStop`'s phrase list, which is Anthropic's wording. codex names its own limit in a
field, and `CodexBackend` reads it — that path is implemented but has no fixture from a real
block. Claude Code publishes no usage at all, so an item running it shows no gauge; that is a
limitation of the transcript, not of this design.
