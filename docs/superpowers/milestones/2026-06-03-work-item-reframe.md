# Milestone: Work-Item Reframe — v0.2.0

- **Shipped:** 2026-06-03
- **Tag:** `v0.2.0`
- **Design spec:** `docs/superpowers/specs/2026-06-02-work-item-reframe-design.md`
- **Discovery-hardening note:** folded into the spec (decision #10)

## Summary

Reframed PR Pilot from a **review-centric** app (a `Review` keyed by a PR number) to a
**work-centric** one: the durable entity is now a **`WorkItem`** that owns a worktree and
a Claude session, with a pull request as optional, late-binding metadata. This lets the
app manage the user's *own* PRs and *pre-PR work* — not just review requests — and
surface objective PR health and branch maintenance. Triggered by a discovery-settings
bug (an unscoped query firehosing strangers' PRs), which is now structurally impossible.

## Phases (each: subagent-driven, two-stage review per task, capstone review, `--no-ff` merge)

| Phase | Delivered | Merge |
|---|---|---|
| **B1.1** | `Review` → unified `WorkItem` (UUID id; PR data in optional `prRef`); non-destructive `store.json` v1→v2 migration (worktree paths preserved) | `bd00fda` |
| **B1.2** | Two-section sidebar (My Work / Review Requests) via derived `category(myLogin:)` | `e7cf55d` |
| **B2** | My-PRs discovery (`author:@me` group); discovery hardening — `queryIsScoped` guard (warn/skip/per-line override) + 100-result circuit-breaker; settings v2→v3 | `6a6062b` |
| **B3** | New Task (branch + worktree + eager session, `prRef: nil`); auto-link/graduation of a PR to its task by `repoKey`+`headBranch` | `ef46cf3` |
| **B4** | PR status chips — CI (`statusCheckRollup`), behind-base (`mergeStateStatus`), changes-requested (`reviewDecision`); non-persisted runtime state | `13182d5` |
| **B5** | Rebase (local, conflict flow) + Push (`--force-with-lease`); editable items get branch worktrees (clean detached converted in place); refresh-guard protects unpushed commits | `1465211` |

## Key accomplishments

1. **Unified `WorkItem` model** — one entity for review requests, the user's PRs, and
   pre-PR tasks; category derived from the attached PR's author, never stored.
2. **Non-destructive migrations** — store v1→v3 across the milestone, verified against
   copies of the user's real data at each step; existing Claude sessions preserved.
3. **Firehose fix** — the original bug class (unscoped discovery query → 100 global PRs)
   is now blocked at input (Settings warning + override) and execution (skip), with a
   circuit-breaker backstop.
4. **Pre-PR task lifecycle** — start work before a PR exists; it graduates to a My PR in
   place when the PR opens, keeping id/worktree/session.
5. **Objective PR health** — CI / behind / changes chips for all PRs, recomputed from
   `gh`, never persisted.
6. **Branch maintenance in-app** — local Rebase with a conflict resolution flow and a
   separate, deliberate Push (`--force-with-lease`), with a guard that never hard-resets
   a worktree holding unpushed commits.

## Stats

- **Span:** 2026-06-02 → 2026-06-03
- **Commits:** 43 (6 phase merges) · **Diff:** 54 files, +6,067 / −529
- **Tests:** 244 passing (Apple Swift Testing) · app builds (xcodebuild)

## Carry-forwards (open, recorded in project memory)

- **Live-data validation:** rebase/push not yet exercised against a real teranode My PR
  (logic is real-git unit/integration tested; no push to the real remote was made).
- **Conversion safety edge:** detached→branch conversion is gated on a clean *working
  tree*; a detached HEAD with unpushed *commits* could be lost — add an `aheadBehind` vs
  `origin/<headBranch>` check before force-removing.
- **Diff-loader `editable` threading:** avoids a create-then-convert churn on first My-PR
  open.
- **Minor:** `.failed` banner "Dismiss"→abort semantics; refresh-guard fails-open if
  `currentBranch` throws; integration tests for My-PR conversion through AppModel and
  `push(id:)` force-flag passthrough.

## Notes

This project uses the superpowers flow (specs + plans + reviewed merges), not GSD; this
file is the milestone record (the GSD `milestones/` archive equivalent).
