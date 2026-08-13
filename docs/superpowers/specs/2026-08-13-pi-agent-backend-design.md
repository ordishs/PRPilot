# pi as an Alternative Agent Backend

**Date:** 2026-08-13
**Status:** Approved

## Problem

PR Pilot drives exactly one agent: Claude Code. The launch path, the transcript watcher and
the status model all encode Claude Code's specifics — its session directory layout, its
transcript filenames, its JSONL event schema, and its `--resume` flag.

`pi` is a lighter coding agent with a comparable CLI surface. We want to run it on real work
inside PR Pilot and compare it against Claude Code on the same sidebar. Today that is
impossible without editing the app.

## Goals

- Run pi in a PR Pilot pane, with the same worktree preparation, status dot and prep log.
- Choose the agent per work item, defaulting from one global setting.
- Keep a session per agent per item, so flipping an item between agents resumes each
  conversation instead of destroying it.
- Leave Claude Code's behaviour bit-for-bit unchanged.

## Non-Goals (YAGNI)

- A third detail tab. Two agents on one work item would share one worktree and fight over
  the same files. Each live session also costs roughly 550 MB against the session cap.
- Per-item pi flags. The existing per-item flags field applies to whichever agent runs.
- Dedicated provider and model settings. Both go in the pi arguments string, mirroring how
  `claudeLaunchArgs` already works.
- A sidebar glyph marking which agent an item uses.
- Any third agent. The protocol admits one, but nothing here is built for it.

## Verified mechanics

Everything below was confirmed by running pi, not read from documentation. The design rests
on these facts.

### pi cannot share Claude Code's session data

| | Claude Code | pi |
|---|---|---|
| Transcript directory | `~/.claude/projects/<encoded cwd>` | `~/.pi/agent/sessions/<encoded cwd>` |
| File name | `<uuid>.jsonl` | `<iso-ts>_<uuid>.jsonl` |
| Assistant line | `type:"assistant"`, `message.stop_reason` | `type:"message"`, `message.role:"assistant"`, `message.stopReason` |
| Turn complete | `stop_reason == "end_turn"` | `stopReason == "stop"` |
| Resume flag | `--resume <id>` | `--session <id>` |

Four independent differences. No shared reader is possible.

### pi's directory encoding preserves spaces and dots

Claude Code replaces every character that is not ASCII-alphanumeric or `-` with `-`. pi does
not. Its rule, confirmed against three real paths:

> Strip the leading `/`, replace remaining `/` with `-`, wrap the result in `--`.

```
/Users/ordishs/dev/masa.gi/code-reviewer
  → --Users-ordishs-dev-masa.gi-code-reviewer--

/private/tmp/.../scratchpad/Application Support/pi.enc test
  → --private-tmp-...-scratchpad-Application Support-pi.enc test--
```

This matters directly. PR Pilot's managed worktree root is
`~/Library/Application Support/PRPilot/worktrees.noindex/…`, so every pi session directory
name will contain a literal space and a literal dot. `TranscriptWatcher` uses `FileManager`
and `open(2)`, so it is safe. Any code that shells out with an unquoted path would break.

The equivalent Claude Code hazard is already documented in `ClaudeTranscriptPath.swift:8`.

### pi accepts a caller-supplied session ID

`pi --session-id <uuid>` creates a session with that exact ID, printing a warning that no
existing session matched. The resulting file is `<iso-ts>_<uuid>.jsonl`. So PR Pilot keeps
generating and owning session IDs exactly as it does now.

### pi's `--resume` is an interactive picker

`pi --resume <id>` opens a full-screen session chooser and waits for keyboard input. Used in
a PR Pilot pane it would hang forever. `pi --session <id>` resumes directly and is the flag
to use.

### pi will not launch without a PATH fix

This was found by the spike and is the one finding that changed the design.

`claude` is a native Mach-O binary. `pi` is a node script whose first line is
`#!/usr/bin/env node`. PR Pilot launches through `/bin/zsh -l -c` with
`environment: nil`, so the child inherits the app's launchd environment. A login shell reads
`.zprofile` and `.zlogin` but **not** `.zshrc`, and nvm sets its PATH in `.zshrc`. Two
consequences, both reproduced:

```
$ env -i HOME=/Users/ordishs /bin/zsh -l -c 'which pi'
pi not found

$ env -i /bin/zsh -l -c "exec /Users/…/v24.14.1/bin/pi --version"
env: node: No such file or directory        # exits 127
```

In the harness this surfaced as an immediate `processTerminated` with raw status 32512, which
is exit 127. pi never drew a single character.

Both are fixed by prepending the resolved pi binary's own directory to PATH. nvm installs
`node` and `pi` as siblings in the same bin directory, so the interpreter is guaranteed to be
there:

```
cd <worktree> && export PATH='<dir of pi>':$PATH && exec '<pi>' …    # works
```

Consequences for the design:

- `AgentBackend` gains `prependsExecutableDirectoryToPath: Bool` — `true` for pi, `false` for
  Claude Code. Making it unconditional would alter the PATH that Claude Code's own child
  processes see, and this design promises Claude Code stays bit-for-bit unchanged.
- `settings.piPath` is effectively **required**, because `LoginShellResolver.resolve("pi")`
  cannot find pi from a GUI-launched app. When resolution fails the pane must show the
  existing unavailable state with pi-specific text naming **Settings ▸ Tools ▸ pi**.

### pi's stop reasons

Counted across existing local sessions: `toolUse` 390, `stop` 19, `aborted` 2, `error` 4.

Only `stop` means pi yielded control to the user. `aborted` and `error` are not completions;
they fall through to the idle-decay path, which is how Claude Code already behaves after an
interrupt.

### Timestamps need no new parsing

pi writes top-level ISO8601 timestamps with fractional seconds
(`2026-08-12T15:49:39.776Z`). Both formatters already in `TranscriptWatcher` accept them.

## Architecture

### Module rename

`ClaudeSessionKit` becomes `AgentKit`; its test target becomes `AgentKitTests`. Types take
agent-neutral names. **Persisted JSON keys do not change** — they stay `claudePath`,
`claudeSessionID`, `claudeFlags` and so on, mapped through `CodingKeys`. So the rename
carries zero data risk.

```
AgentKit/
  AgentSession.swift          (was ClaudeSession — rename only, unless the spike says otherwise)
  AgentSessionState.swift      (was ClaudeSessionState)
  AgentStatus.swift            (was ClaudeStatus)
  AgentStatusReader.swift      (was ClaudeStatusReader)
  AgentTerminalTheme.swift     (was ClaudeTerminalTheme)
  AgentLaunchBuilder.swift     (was ClaudeLaunchBuilder)
  AgentTranscriptPath.swift    (was ClaudeTranscriptPath)
  TranscriptWatcher.swift      (name unchanged)
  LaunchPrompt.swift           (unchanged)
  StatusDotView.swift          (unchanged)
  Backends/
    AgentBackend.swift
    ClaudeCodeBackend.swift
    PiBackend.swift
```

### The backend protocol

```swift
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case pi
}

public struct TranscriptParseState: Sendable {
    var pendingWorkflows: Int = 0
}

public protocol AgentBackend: Sendable {
    var kind: AgentKind { get }
    var displayName: String { get }            // "Claude Code" | "pi"
    var defaultExecutableName: String { get }  // "claude" | "pi"

    /// pi is a node script with an `env node` shebang, and a GUI-launched login shell has no
    /// nvm PATH. Prepending pi's own bin directory supplies the sibling `node`. False for
    /// Claude Code, which is a native binary — see "pi will not launch without a PATH fix".
    var prependsExecutableDirectoryToPath: Bool { get }

    func transcriptDirectory(forWorktreePath path: String) -> URL
    func sessionID(fromTranscriptFilename name: String) -> String?

    func launchArguments(
        settings: Settings,
        review: WorkItem,
        sessionID: String,
        resume: Bool
    ) -> [String]

    func parse(line: Data, state: inout TranscriptParseState) -> TranscriptEvent?
}
```

Two conformances, `ClaudeCodeBackend` and `PiBackend`. Nothing else in the app knows an
agent's specifics.

Throughout this document, **effective agent** means `item.agent ?? settings.defaultAgent`.
It resolves at every point of use rather than being written back to the item, so changing the
global default moves every item that has no explicit choice.

`AgentSession` is renamed but otherwise untouched **if** the spike in "Risks" shows pi needs
no keyboard handling of its own. If pi does need it, `installShiftReturnMonitor` becomes
per-agent behaviour and this design gains a task. That is the one place where the spike can
widen the work.

### Generic transcript path handling

`AgentTranscriptPath` takes a backend and implements `latestSessionID`, `transcriptExists`
and `archiveTranscripts` on top of `transcriptDirectory` plus
`sessionID(fromTranscriptFilename:)`.

`transcriptExists` must change shape. Today it builds `<dir>/<id>.jsonl` by concatenation
(`ClaudeTranscriptPath.swift:27`). pi's timestamp prefix is unknown to the caller, so that
cannot work. The new implementation lists the directory, maps each filename to a session ID,
and tests membership. That is correct for both backends.

`archiveTranscripts` needs no logic change — it moves every `.jsonl` into `archived/`.

### Transcript parsing

`TranscriptWatcher` keeps its directory source, file source, read-offset bookkeeping and
replay-on-attach behaviour. Its hardcoded decoders move into the backends.

`ClaudeCodeBackend.parse` carries today's logic verbatim, including the three-signal
`pendingWorkflows` accounting described in `TranscriptWatcher.swift:186`.

`PiBackend.parse`:

- Accept lines where `type == "message"` and `message.role == "assistant"`.
- Snippet: first `content[]` block of type `text`, truncated to 80 characters.
- `turnCompleted = (message.stopReason == "stop")`.
- `workflowPending` is always `false`. pi has no workflow concept, so the whole branch is
  inert rather than wrong.

## Data model

`ReviewStore` migrates additively: every field decodes with `decodeIfPresent`, and the store
re-encodes on load when the schema version lags (`ReviewStore.swift:78`). New optional fields
therefore need no version bump and no bespoke migration.

### `WorkItem`

| Change | Detail |
|---|---|
| add `agent: AgentKind?` | `nil` means "follow the global default". A pre-existing item decodes to `nil`. |
| add `piSessionID: String?` | `claudeSessionID` becomes the Claude Code slot only. |
| add `sessionID(for:)` / `setSessionID(_:for:)` | Keeps call sites free of branching. |
| rename `claudeFlags` → `agentFlags` | Swift name only. JSON key stays `claudeFlags`. Applies to whichever agent runs. |

### `Settings`

| Field | Default |
|---|---|
| `defaultAgent: AgentKind` | `.claudeCode` |
| `piPath: String?` | `nil` — resolved from the login PATH |
| `piLaunchArgs: String` | `""` |
| `piEnv: String` | `""` |
| `piReviewPromptTemplate: String` | `"Review the pull request at {url}."` |
| `piIssuePromptTemplate: String` | `"Start work on issue {number}."` |

`maxLiveClaudeSessions` keeps its JSON key and takes the Swift name `maxLiveAgentSessions`.
The cap counts both agents together, because it guards memory and memory does not care which
binary is running.

Provider and model selection goes in `piLaunchArgs`, for example
`--provider anthropic --model '*sonnet*'`. `AgentSession.makeShellCommand` already inserts
`extraArgs` before the built arguments, which pi's parser accepts.

**Open point for the user.** The two pi prompt template defaults are a guess. `/review` and
`/start-issue` are Claude Code slash commands with no pi equivalent, so plain prose is the
safe default. Expect to tune both once pi runs.

## Launch and resume

`AgentLaunchBuilder.build` resolves the backend from the item's effective agent and delegates
to `launchArguments`.

| | fresh | resume |
|---|---|---|
| Claude Code | `--name <n> --session-id <id> [prompt]` | `--name <n> --resume <id>` |
| pi | `--name <n> --session-id <id> [prompt]` | `--name <n> --session <id>` |

`--name` and `--session-id` behave identically across both agents. The resume flag is the
only divergence, and using `--resume` for pi would hang the pane.

`AppModel.claudeExecutable()` becomes `agentExecutable(for: kind)`. It reads `settings.piPath`
then falls back to `LoginShellResolver.resolve("pi")`. The not-found message must name the
correct binary and the correct Settings row — today's text hardcodes `which claude` and
**Settings ▸ Tools ▸ claude**.

The session-ID selection logic in `AppModel.ensureClaudeSession` (around
`AppModel.swift:640`) reads and writes the per-agent slot instead of `claudeSessionID`. Its
three-way decision — stored ID with a live transcript, stored ID whose transcript vanished,
or no stored ID — is unchanged.

## UI

### Pane title

`PaneSelection.claude` keeps its raw value, because it is persisted in `lastPane`. Its
`displayName` becomes `displayName(for: AgentKind)`, returning "Claude Review" or
"pi Review". Callers pass the item's effective agent.

### Agent picker

A menu in the detail pane's top-trailing corner, beside the existing prep-log toggle in
`ClaudePaneView`. It shows the effective agent and marks whether that came from the item or
the global default.

### Settings

- **Tools** gains a `pi` path row beside `claude`, a **Default agent** picker, and pi
  arguments and environment rows.
- **Prompts** gains the two pi templates.

### Switching an item's agent

1. Terminate the live session and drop it from the session dictionary.
2. Stop and detach the transcript watcher.
3. Persist the new `agent` on the item.
4. Call `ensureAgentSession`, which resumes that agent's own stored session ID when its
   transcript still exists, and otherwise starts fresh.

Both transcripts stay on disk in their own trees. Flipping back and forth resumes each
conversation.

## Order of work

The spike gates everything. After it, the rename lands alone so its large mechanical diff
never mixes with behavioural change.

1. ~~Throwaway spike — prove pi renders in SwiftTerm.~~ **Done 2026-08-13, passed.** It also
   forced the PATH fix above. Harness discarded; it lived outside the repo.
2. Rename `ClaudeSessionKit` to `AgentKit` and its types, keeping every JSON key. Full suite
   green with no behavioural change.
3. Introduce `AgentBackend` plus `ClaudeCodeBackend`, moving the launch and parse logic
   behind it. Full suite still green — Claude Code behaviour is unchanged by construction.
4. Add `PiBackend` and its tests.
5. Add the `WorkItem` and `Settings` fields, plus the effective-agent resolution.
6. Add the UI — pane title, agent picker, Settings rows, switch flow.
7. End-to-end verification against a live pi session.

Steps 2 and 3 are refactors with no user-visible change. Their proof is the unchanged suite.

## Testing

Rename `ClaudeSessionKitTests` to `AgentKitTests`. Every existing test must still pass with
unchanged behaviour — that is the guard on the Claude Code path.

New tests:

- **`PiBackendTests`**
  - Directory encoding for four real paths, including the space-and-dot case.
  - `sessionID(fromTranscriptFilename:)` strips both the timestamp prefix and the extension.
  - Launch arguments for fresh and resume, asserting `--session` and never `--resume`.
  - `parse` over real pi JSONL lines covering all four `stopReason` values, asserting
    `turnCompleted` only for `stop`.
- **`AgentTranscriptPathTests`** — `latestSessionID`, `transcriptExists` and
  `archiveTranscripts` exercised against both backends, including a pi transcript whose
  timestamp prefix the caller does not know.
- **`WorkItemAgentTests`** — decode a store JSON captured before this change; assert
  `agent == nil`, `claudeSessionID` preserved, `piSessionID == nil`.
- **`AppModelTests`** — switching an item's agent keeps both session IDs and resumes each.

End-to-end, in the built app: launch pi on a real worktree and confirm the status dot moves
working → awaiting input. That is the only proof the watcher fires against a live pi session.

Note that `drainReleasesAnIdleSessionAtTheCapAndStartsTheNext` is a known intermittent
failure on a clean tree. Confirm it fails before this work, so it is not read as a
regression.

## Risks

### pi's TUI in SwiftTerm — RESOLVED, spike passed

Retired as a risk on 2026-08-13. A throwaway SwiftTerm harness reproduced
`AgentSession.start()` exactly — `/bin/zsh -l -c "cd <wt> && exec pi …"`, `environment: nil`,
the same theme colours — and ran pi inside the real
`bsv-blockchain-teranode-issue-4459-limit-transactions-in-ram` worktree.

pi rendered correctly: coloured context banner, box drawing, the tool-call result block, the
bottom status line, and a live cursor. It executed a bash tool call and answered the prompt.
No layout corruption.

The spike also confirmed the directory encoding rule against a real PR Pilot worktree, space
and dot intact:

```
--Users-ordishs-Library-Application Support-PRPilot-worktrees.noindex-bsv-blockchain-teranode-issue-4459-limit-transactions-in-ram--
```

**Still unproven:** keyboard handling. `installShiftReturnMonitor` is already conditional on
`view.terminal.keyboardEnhancementFlags.isEmpty`, and pi negotiates the Kitty keyboard
protocol (`ESC [ > 7 u` observed at launch), so the monitor should stand down on its own and
`AgentSession` should need no change. Confirming that needs a human pressing Shift+Return in a
pi pane. It is a step in the end-to-end verification, not a design question.

### pi bills as extra usage

Observed at launch: pi runs through the local `pi-claude-auth` extension on Anthropic
subscription auth, and warns that third-party harness usage draws from extra usage rather than
Claude plan limits. Not a code risk. It is a cost risk worth knowing before running pi across
a full sidebar.

### Directory encoding is reverse-engineered

The rule matches three observed paths and one deliberately hostile one. It is not documented
by pi. A future pi release could change it, and PR Pilot would then tail an empty directory
and leave status stuck at `.starting` — the same failure mode the comment in
`ClaudeTranscriptPath.swift:8` warns about for Claude Code. The `PiBackendTests` encoding
cases are what would catch it.
