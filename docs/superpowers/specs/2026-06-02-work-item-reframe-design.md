# Work-Item Reframe — My PRs, Tasks & PR Status

- **Date:** 2026-06-02
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Builds on:** `2026-05-27-pr-review-app-design.md`
- **Working title:** Work-item reframe (PR Pilot)

## Summary

PR Pilot today manages **PRs the user has been asked to review**. This reframe
generalises the central entity from a *review* (keyed by a PR number) to a **work
item** — a unit of work that owns a git worktree and a Claude session, and *optionally*
has a pull request attached. This unlocks three things in one model:

1. **My PRs** — PRs the user authored, managed alongside review requests but with
   different behaviour (no auto-review; rebase/push actions).
2. **Tasks before a PR exists** — a "New task" creates a branch + worktree + Claude
   session immediately; when a PR is later opened from that branch it links in place.
3. **PR status at a glance** — CI result, out-of-date-with-base, and ready-for-review,
   shown for every PR regardless of who authored it.

The reframe is deliberate: the durable entity becomes the *unit of work*, and a PR is a
late-binding event attached to it. "My PR" is then simply a work item whose attached PR
was authored by the user; a "review request" is one whose PR was authored by someone
else; a "task" is one with no PR yet.

## Goals

- One unified entity for everything the app manages, with PR attachment optional.
- Surface and manage the user's own PRs, not just review requests.
- Start the work lifecycle *before* a PR exists, then graduate to a PR with no manual
  re-filing.
- Objective PR health (CI / freshness / readiness) visible in the sidebar.
- Local rebase and explicit push for owned branches, with CI triggered only on demand.

## Non-goals (for now)

- Replacing GitHub for PR creation conversation/merge — the web view remains.
- Multi-PR-per-work-item. One work item attaches at most one PR.
- Cross-repo auto-linking. Linking is scoped to a single registered repo.
- Re-designing the three panes (Claude / GitHub / Diff) — unchanged.

## Key decisions (decision log)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Scope/sequence | **Reframe to work items first** (vs additive "My PRs" bolt-on) | Do the identity-model surgery once; everything else builds on it |
| 2 | Entity model | **Unify**: one `WorkItem`; `Review` becomes a kind of it | Avoids two parallel models + linking/dedup between them |
| 3 | Identity | **Internal UUID**; branch + `prRef` are attributes | Stable before a PR, across PR attach, branch rename, forks |
| 4 | Sidebar taxonomy | **Two sections**: My Work + Review Requests | A task graduates to a My PR *in place*, matching the lifecycle |
| 5 | Category | **Derived, never stored** (from `prRef` + author) | No redundant state; graduation is automatic |
| 6 | New task | **Minimal inputs + eager Claude session** | The point is to start working in seconds |
| 7 | PR linking | **Automatic by `repoKey` + `headBranch`**, manual fallback | Zero-friction graduation; repo-scoped to avoid collisions |
| 8 | Rebase vs push | **Separate actions**; rebase is local-only | Avoid kicking off long CI on every rebase |
| 9 | Type rename | `Review` → `WorkItem` across packages | A pre-PR task is not a "review"; name should not lie |
| 10 | Discovery hardening | **Warn + skip unscoped queries, explicit per-line override**; structured queries; 100-cap circuit-breaker | An unscoped line silently firehosed 100 global PRs; guard at input *and* execution |

## Data model

The unified durable entity. Volatile/derived state (Claude status, live PR metadata,
diff, CI/freshness/readiness) is still **recomputed from disk/`gh`/`git`**, never
persisted — per the existing core principle.

```
WorkItem
  id              UUID            stable identity (no longer the PR number)
  title           String          defaults to branch name until a PR supplies one
  repoKey         String          which RegisteredRepo / clone this belongs to
  baseBranch      String
  headBranch      String?         the branch we own; nil for detached review checkouts
  worktreePath    String?         set once, never changes → Claude session path stays stable
  prRef           PRRef?          optional attached pull request
  prState         PRState?        cached: open | draft | merged | closed
  claudeSessionID String?
  claudeFlags     [String]?
  autoReview      Bool            default derived from category; user-overridable
  notes           String?
  addedAt         Date
  lastOpenedAt    Date?
  disabled        Bool
  viewedFiles     [String]
  approvedByMe    Bool

PRRef
  owner, repo, number, url
  authorLogin     String          drives category derivation
```

### Category (derived)

```
category(item):
  prRef == nil                         -> .task           (section: My Work)
  prRef.authorLogin == myLogin         -> .myPR           (section: My Work)
  else                                 -> .reviewRequest  (section: Review Requests)
```

`myLogin` is fetched once via `gh api user --jq .login` and cached (runtime; refreshed
on launch). A user cannot be asked to review their own PR, so `.myPR` vs
`.reviewRequest` is unambiguous.

### Worktree / branch strategy by category

This is the enabler for rebase/push on owned work.

| Category | Worktree checkout | Editable |
|---|---|---|
| Task | `git worktree add -b <branch> <path> <base>` (new local branch off base) | yes |
| My PR | worktree **on the head branch** tracking the remote (not detached) | yes — commit / rebase / push |
| Review Request | detached at fetched `refs/pull/N/head` (today's behaviour) | no — read-only |

Worktree directory naming:
- Owned work (task, My PR): `<owner>-<repo>-<branch-slug>`
- Review checkout: `<owner>-<repo>-pr<N>`

`worktreePath` is stored once and never changes — even when a task graduates to a My PR —
so the derived Claude transcript path (`~/.claude/projects/<encoded-worktree-path>`)
remains valid across the item's whole life.

### Migration

A `ReviewStore` schema-version bump runs a one-time migration on decode:

1. Mint a UUID `id` for each existing review.
2. Move `owner/repo#number` + author into `prRef`; set `prState` from the old field.
3. **Preserve `worktreePath`** verbatim so existing Claude sessions still resolve.
4. Category falls out of the author: items authored by the user become My PRs, the rest
   Review Requests.
5. Migrated items remain detached (no `headBranch`) until next refreshed onto their
   branch — only relevant for My PRs the user later wants to rebase.

The migration must be idempotent and must not drop or orphan any existing item or its
session. Covered by a `ReviewStore` round-trip + migration unit test using a fixture of
the pre-migration JSON.

## Discovery & linking

### Two query groups (Settings)

Independently enable/disable-able, each polled on its own:

- **Review requests** — defaults: `review-requested:@me is:open`, `assignee:@me is:open`.
- **My PRs** — default: `author:@me is:open`. `@me` is self-scoping (returns only the
  user's PRs); per-line org/repo scope is allowed.

All results merge into one set **deduped by `prRef`**, then categorised by author. Query-
set provenance is *not* stored — author alone decides the category.

Each query is a structured value rather than a bare string, so a line can carry the
override flag the hardening needs:

```
DiscoveryQuery
  text         String   the gh search prs query line
  allowUnscoped Bool     user override: run even if it has no scope qualifier (default false)
```

Settings holds two ordered lists of these (`reviewRequestQueries`, `myPRQueries`),
each with its own enabled flag. Migration: the existing `[String] discoveryQueries`
becomes `reviewRequestQueries`; `myPRQueries` starts with the single default
`author:@me is:open`.

## Discovery hardening

**Problem this fixes:** the app runs any query verbatim, so an *unscoped* line — one with
no qualifier tying results to the user, an org, or a repo (e.g. bare `is:open` or
`is:pr`) — silently returns the 100 most recent open PRs across all of GitHub. This is
what flooded the sidebar with ~75 strangers' PRs during discovery experimentation.

**Scope check (pure, shared, testable):**

```
queryIsScoped(text) -> Bool
  scoped if text contains at least one relevance-bounding qualifier:
    author: | review-requested: | assignee: | mentions: | involves: | commenter:
      (any @me or login)
    user: | org: | repo:
  unscoped otherwise (only is: / archived: / draft: / labels / dates / language / free text)
```

(The check tests for the *presence* of a bound, not identity — `author:someone-else` is
still scoped, just to that person, so it can't firehose.)

**Two enforcement layers + a circuit-breaker** (per decision #10, "warn + skip with
explicit override"):

1. **Settings (input):** an unscoped line is flagged inline with a warning ("not scoped
   to you, an org, or a repo — would match PRs across all of GitHub") and a per-line
   **"run anyway"** toggle (sets `allowUnscoped`). Until toggled, the line is marked
   won't-run.
2. **Execution (defense-in-depth):** `discoverNow` re-checks every query with
   `queryIsScoped` before running it (because `store.json` can be hand-edited). An
   unscoped line without `allowUnscoped` is **skipped, not run**, and a non-fatal
   warning is surfaced (banner / discovery status), naming the offending line.
3. **Circuit-breaker (scoped-but-huge):** if a single query returns at/near the 100
   result cap, the flood is **not** auto-merged. Discovery surfaces "query returned
   100+ results — likely too broad" and requires confirmation before adding, catching
   technically-scoped-but-enormous queries (e.g. a whole busy org).

The check is intentionally conservative: it only blocks lines that *cannot* be
relevance-bounded. A user who genuinely wants a broad query flips "run anyway."

### Linking (task → My PR), automatic

For each discovered My PR:

- Find an existing `WorkItem` with matching **`repoKey` + `headBranch`** (matched within
  the same repo only, so branch-name collisions across repos cannot cross-link).
- Match found with `prRef == nil` → attach `prRef` (the task graduates in place; gains a
  `#number` badge).
- No match → create a fresh My PR `WorkItem` (worktree on the head branch, created lazily
  on first open).
- A manual **"Link PR…"** action is the fallback for odd cases (e.g. branch renamed after
  the PR was opened).

### Auto-review by category

Only **Review Requests** auto-start a Claude review (gated by the existing `autoLoad`
setting). Tasks and My PRs **never** auto-review; their session opens ready for the user
to drive. `autoReview` on the item defaults from category but is user-overridable.

## PR status indicators

Derived at runtime via `gh`, never persisted. Computed per open-PR item on the poll
tick:

| Indicator | Source | Shown as |
|---|---|---|
| CI | `gh pr view --json statusCheckRollup` (aggregated) | ✓ pass · ✗ fail · ◷ pending · – none |
| Out-of-date | `gh pr view --json mergeStateStatus` (`BEHIND`) | "behind" chip |
| Ready for review | `gh pr view --json isDraft,reviewDecision` | draft · ready · approved · changes |

These apply to **all** PRs (My PRs and Review Requests alike). A pre-PR **task** has no
PR to query and instead shows **local** status from `git` — commits ahead of base, dirty
worktree — which costs no `gh` call.

Polling cost: one `gh pr view` per open PR per tick. Acceptable at single-user scale;
tasks without PRs are free. Could be batched via GraphQL later if needed.

## Rebase & push

Two **separate** context-menu actions on editable My Work items, so a long CI run is
only ever triggered deliberately.

**Rebase on `<base>`** — local only, available when the item is editable and behind base:

1. `git -C <wt> fetch origin <base>`
2. `git -C <wt> rebase origin/<base>`
   - **Clean** → done. Branch now shows "ahead/diverged — not pushed."
   - **Conflict** → leave the worktree mid-rebase; show a banner *"Rebase paused — N
     conflicts"* with **[Resolve in Claude]** (focuses the Claude pane in the worktree),
     **[Abort]** (`git rebase --abort`), and once resolved **[Continue]**
     (`git rebase --continue`).
3. **Never pushes.**

**Push** — separate action; the user decides when CI runs:

- `git push --force-with-lease` when history diverged (post-rebase), plain `git push`
  otherwise. Never a bare `--force`.
- Disabled when there is nothing to push.
- Independently useful for a pre-PR task: work in the worktree, then **Push** when ready
  (a PR can follow via Create PR…).

## UI

### Sidebar

Two sections (extends the existing `SidebarGrouping`/section rendering in `ContentView`):

- **MY WORK** — header carries **`+ New task`** and "Add PR by URL". Holds tasks + My
  PRs. An item gains a `#number` badge in place when its PR links.
- **REVIEW REQUESTS** — discovered/assigned PRs by others.

Row: title-or-branch · (`repo · author` *or* "no PR yet") · status chips (CI / behind /
ready) + the existing Claude status dot. Disabled items fade as today.

### New task flow

A minimal sheet:

- **Repo** (shown only if more than one registered) · **Branch** (new branch name) ·
  **Base** (defaults to the repo's `defaultBase`).
- On Create: `git worktree add -b <branch> <path> <base>`, start a live Claude session,
  select the item, and focus the Claude pane.
- Title defaults to the branch name until a PR supplies one.

### Context menus

- **My Work (editable):** Rebase on `<base>` · Push · Create PR… (runs `gh pr create` in
  the worktree; falls back to opening the compare URL if that fails) · Open PR in browser
  (if linked) · — · Copy Session ID · Clear Claude Session · Disable/Enable · Remove.
- **Review Requests:** unchanged from today (no rebase / push / create-PR).
- **Remove** on a task warns if the branch has **unpushed commits or a dirty worktree**
  before deleting the worktree/branch.

## Build phasing

Front-loads the risky model change; each step is independently usable.

| Step | Delivers | Usable at end? |
|---|---|---|
| **B1 · Model unify + migration** | `Review`→`WorkItem`, UUID identity, `prRef`, derived category, two-section nav | Existing items keep working under the new model |
| **B2 · My PRs discovery + hardening** | Structured two-group queries, author categorisation, My-PR worktree-on-branch, auto-linking, **scope check + warn/skip/override + 100-cap circuit-breaker** | My PRs appear and are managed; unscoped queries can't firehose |
| **B3 · New task** | Minimal eager-Claude creation flow | Start work before a PR exists |
| **B4 · Status enrichment** | CI / behind / ready chips; local status for tasks | PR health at a glance |
| **B5 · Rebase + Push** | Context actions + conflict flow | Keep owned branches current on demand |

Each step gets its own plan → implementation cycle.

## Testing strategy

Following the existing package-centric approach:

- **`ReviewStore`** — schema migration from a pre-migration JSON fixture; round-trip;
  idempotency; no item/session loss.
- **Category derivation** — pure function over `prRef` + `myLogin`; table-driven.
- **Linking** — given discovered My PRs and existing items, assert correct attach-vs-
  create and repo-scoped matching (no cross-repo links).
- **`WorktreeKit`** — branch-based vs detached creation against throwaway temp repos;
  rebase clean/conflict/abort/continue; push diverged (`--force-with-lease`) vs plain;
  "nothing to push" disabled state.
- **`GitHubKit`** — injected runner with canned `--json` for `statusCheckRollup`,
  `mergeStateStatus`, `isDraft`/`reviewDecision`; two query groups; dedup by `prRef`.
- **`queryIsScoped`** — pure function, table-driven: scoped vs unscoped lines (each
  qualifier variant with `@me` and with a login; bare `is:open`/`is:pr`/labels/dates →
  unscoped). Execution-layer test: an unscoped line without `allowUnscoped` is skipped
  and warned, with `allowUnscoped` it runs; circuit-breaker fires at the 100-cap.
- **UI** stays thin → minimal; real `gh`/`git` covered by the manual E2E checklist.

## Open questions / risks

- **Rename churn** (`Review`→`WorkItem`) across 5 packages + UI — mechanical but wide;
  do it as the first, isolated step (B1).
- **Migration safety** — must not lose any of the existing items or orphan their Claude
  sessions; `worktreePath` preservation is load-bearing.
- **Forked My PRs** — pushing needs access to the fork's head repository; remote/branch
  naming and the `--force-with-lease` ref get fiddly. Validate against a real forked PR
  early in B5.
- **`gh` polling cost / rate limits** — one `gh pr view` per open PR per tick; mitigated
  by querying only open PRs (tasks are free); batch via GraphQL if it bites.
- **Auto-link mis-match** — mitigated by matching within `repoKey` only; manual "Link
  PR…" is the escape hatch.

## Firehose incident — root cause (now addressed in-scope)

The discovery firehose that pulled ~75 strangers' PRs was **not** the `author:ordishs`
line (verified against the live `gh`: that line returns exactly the user's 2 PRs). The
cause was a *different*, under-constrained experimental line — a bare `is:open`/`is:pr`
with no scope qualifier — which `gh search prs` answers with the 100 most recent open
PRs across all of GitHub. The query syntax and the app's tokenisation are both fine; the
defect was the **absence of any guardrail** around an unscoped query. This is fixed by
the Discovery hardening section above (decision #10), landed in build step B2.
