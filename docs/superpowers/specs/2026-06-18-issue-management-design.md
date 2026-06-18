# Issue Management — Design

**Date:** 2026-06-18
**Status:** Approved

## Goal

Extend PRPilot, which today monitors pull requests the user has been asked to
review, so it also manages GitHub **issues assigned to the user**. When an
assigned issue is seen for the first time the app must:

1. Ensure the issue's repository is cloned locally.
2. Create a git worktree for the issue (a fresh branch off the repo's base).
3. Show the issue's URL in the GitHub pane.
4. Start a Claude Code session that evaluates the issue.

## Key decisions

- **Claude behavior on first sight:** evaluate only — launch `/start-issue`
  (read + plan in plan mode, stop before editing). Not auto-fix.
- **Sidebar placement:** a dedicated third "Issues" section (separate from
  "My Work" and "Review Requests").
- **Branch naming:** `issue-<number>-<title-slug>`.
- **Auto-start:** discovering a new issue immediately prepares its worktree and
  starts the Claude session, regardless of the `autoLoad` setting. The
  `issuesEnabled` toggle is the gate.

## Design rationale

An assigned issue is a third variant of the existing `WorkItem` model. PRPilot
already supports `WorkItem`s with no PR (freeform "tasks" created via *New
Task*), and the *New Task* flow already does exactly the heavy lifting this
feature needs: it clones on demand (`WorktreeManager.resolveClone`), creates a
new branch worktree (`createBranchWorktree`), and launches a Claude session. An
issue is therefore "a task that carries an issue reference and launches a
different initial command." The only genuinely new machinery is **issue
discovery**, an **issue reference on the model**, and an **issue-specific Claude
launch command**.

## Components

### 1. Model (`PRPilotModels`)

- New `IssueRef`: `{ owner: String, repo: String, number: Int, url: URL,
  authorLogin: String }`.
- `WorkItem.issueRef: IssueRef?` — new optional field decoded with
  `decodeIfPresent`. Existing `store.json` items (no `issueRef`) decode
  unchanged; **no migration and no schema-version bump required.**
- `WorkItemCategory` gains a `.issue` case.
- `WorkItem.category(myLogin:)` precedence:
  - `prRef != nil` → `.myPR` (author is me) or `.reviewRequest`.
  - else `issueRef != nil` → `.issue`.
  - else → `.task`.
- Accessors:
  - `url` → `prRef?.url ?? issueRef?.url`.
  - `number` **stays PR-only** (`prRef?.number`). This is load-bearing: the
    worktree provider branches on `review.number` to decide between fetching
    `refs/pull/N/head` (PR) and creating a fresh branch (task/issue). Keeping
    `number == nil` for issues routes them down the new-branch path.
  - new `issueNumber` → `issueRef?.number`.
  - `author` → `prRef?.authorLogin ?? issueRef?.authorLogin`.
  - a display-number helper that returns the PR number or, failing that, the
    issue number (for titles like `#123`).

### 2. Discovery (`GitHubKit`, `PRPilotModels.Settings`, `AppCore.AppModel`)

- `GitHubClient.searchIssues(query:) -> [IssueHit]`:
  - runs `gh search issues <tokens> --json
    number,title,url,state,author,repository --limit 100`.
  - appends `is:issue` to the token list to exclude PRs (`gh search issues`
    otherwise returns both).
  - `IssueHit` mirrors `DiscoveryHit` minus `isDraft`; key is
    `"<owner>/<repo>/issues/<number>"` so it never collides with the PR key
    `"<owner>/<repo>#<number>"`.
- `Settings`:
  - add `issueQueries: [DiscoveryQuery]` (default
    `[DiscoveryQuery(text: "assignee:@me is:open")]`) and
    `issuesEnabled: Bool` (default `true`).
  - both decoded backward-compatibly (`decodeIfPresent` + defaults).
- `AppModel.discoverNow`:
  - add a third group for issues, gated on `settings.issuesEnabled`, querying
    `searchIssues`. Reuse the existing scoping check and the "100+ results"
    guard.
  - `mergeDiscoveredIssues(_:)`:
    - dedupe existing issue items by the issue key.
    - issue open/closed state is stored in the existing `prState` field, mapped
      `OPEN → .open`, `CLOSED → .closed` (`draft`/`merged` never apply to
      issues). This lets `sidebarStatus` and the prune logic work uniformly
      across PRs and issues without a parallel field.
    - **existing** item → refresh `title` and `prState`.
    - **new** item → build a `WorkItem`:
      - `headBranch = "issue-<n>-<slug>"` where `slug` is a length-capped,
        sanitized title (reuse `WorktreeManager.branchSlug` semantics).
      - `baseBranch` from `registeredDefaultBase(...)` if known, else
        `client.fetchDefaultBase(owner:repo:)`, else `"main"`.
      - `issueRef` set, `prRef = nil`, `origin = .discovered`,
        `addedAt = now`.
      - persist, then auto-start (see §3).
  - prune stale discovered issues whose state is closed and which are no longer
    in the current hit set (mirrors `pruneStaleDiscoveredReviews`).

### 3. Auto-start on first sight

A newly discovered issue unconditionally calls `ensureClaudeSession(for:)` and
`webPreloadHandler?(item)` — independent of `settings.autoLoad`, because
auto-starting evaluation is the core promise of the feature. This runs in the
background and must **not** change `selection`. `ensureClaudeSession` already
drives clone → worktree → session and reports progress/failure through the
existing `claudePaneState` machinery.

### 4. Worktree — no new code

An issue `WorkItem` has `headBranch` set and `number == nil`, so
`WorktreeProvider.ensureWorktree` routes it through `editableWorktree →
createBranchWorktree` (new branch off base), and `resolveClone` clones on
demand. Verified against the current implementation; nothing to add here.

### 5. Claude launch (`ClaudeSessionKit.ClaudeLaunchBuilder`)

In the non-resume branch of `build(...)`:

- `prRef != nil` → `/review <url>` (unchanged).
- else `issueRef != nil` → `/start-issue <issueNumber>` (evaluate only).
- else (task) → no initial command (unchanged).

`sessionName(for:)` for an issue → `#<issueNumber> <title>`.

### 6. UI (`App`)

- **`ContentView` sidebar:** add a third collapsible `Section` titled "Issues",
  fed by a new `issues` bucket from `sidebarSections`. Add an
  `issuesCollapsed` setting (backward-compatible) and a section color band
  consistent with the existing two.
- **`SidebarSections.sidebarSections`:** return an `issues` array; route
  `.issue` items into it; `.task`/`.myPR` → `myWork`; `.reviewRequest` →
  `reviewRequests`.
- **`DetailView.defaultPaneForSelection`:** issues default to the **GitHub
  pane** (read the issue while Claude works). Fix the existing condition so only
  true tasks (`prRef == nil && issueRef == nil`) default to the Claude pane.
  `WebPane` already renders `review.url`, which now resolves for issues.
- **Add Issue by URL:** new "Add Issue by URL…" menu item +
  `AddIssueSheet` (symmetric to `AddPRSheet`) + `IssueLocator` (parses
  `/<owner>/<repo>/issues/<number>`; rejects pull and non-github URLs) +
  `AppModel.addIssue(urlString:)` (fetch issue, upsert, select, prefetch).
- **`SettingsView`:** one additional `querySection("Issues", rows:…,
  enabled:…)` using the existing helper, wired to `issueQueries` /
  `issuesEnabled`.

## Data flow

```
poll tick
  → GitHubClient.searchIssues("assignee:@me is:open is:issue")
  → AppModel.mergeDiscoveredIssues
      → new WorkItem (issueRef, headBranch=issue-<n>-<slug>, origin=.discovered)
      → store.upsertItem
      → ensureClaudeSession      → resolveClone (clone if missing)
                                  → createBranchWorktree
                                  → ClaudeLaunchBuilder → /start-issue <n>
      → webPreloadHandler        → WebViewCache loads issue URL
  → sidebar "Issues" section shows item
  → user selects → GitHub pane shows the issue, Claude pane is evaluating
```

## Error handling

Reuses existing mechanisms: `claudePaneState` (`preparingWorktree`,
`worktreeFailed`, `claudeUnavailable`), per-query failures are skipped, scoping
warnings and the "100+ results (too broad)" guard apply to issue queries too.

## Testing

Unit (existing harness — stub `CommandRunner`, fakes in `AppModelTests`):

- `WorkItem`: `category`, `url`, `issueNumber`, `author` for issue items;
  Codable round-trip with `issueRef`; backward-compat decode of legacy JSON
  without `issueRef`.
- `IssueLocator`: parses a valid issue URL; rejects a pull URL and a
  non-github URL.
- `GitHubClient.searchIssues`: parses fixture JSON into `IssueHit`s; `is:issue`
  is appended.
- `ClaudeLaunchBuilder`: issue item → `/start-issue <n>`; `sessionName` →
  `#<n> <title>`.
- `sidebarSections`: an issue item lands in the issues bucket, not myWork.
- `Settings`: decode without `issueQueries`/`issuesEnabled` yields defaults.
- `AppModel`: discovering an issue creates a `WorkItem` with the generated
  branch and triggers session preparation (via fakes).

End-to-end (manual): a real assigned issue is discovered, its repo is cloned,
a worktree is created, the GitHub pane shows the issue, and a real `claude`
session starts on `/start-issue`.

## Out of scope

- Auto-fixing issues (`/fix-issue`) or pushing PRs for issues automatically.
- Linking discovered issues to PRs that close them (the cosmetic
  `closingIssueNumber` already exists and is untouched).
