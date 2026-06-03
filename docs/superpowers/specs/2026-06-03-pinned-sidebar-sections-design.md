# Pinned Sidebar Sections — My Work vs Review Requests as permanent structure

- **Date:** 2026-06-03
- **Status:** Draft
- **Builds on:** `2026-06-02-work-item-reframe-design.md`
- **Working title:** Pinned sidebar sections

## Summary

The work-item reframe already derives a category for every item (`task` / `myPR` /
`reviewRequest`) and exposes a **My Work** vs **Review Requests** split — but only as
*one of five optional grouping modes* (`SidebarGrouping.byCategory`, alongside `none`,
`byDate`, `byAuthor`, `byStatus`). Pick any other grouping and the separation vanishes.

This change promotes that split from an optional sort to **permanent top-level
structure**. The sidebar always shows two pinned, collapsible sections — **My Work** on
top, **Review Requests** below — with strong, accent-coloured headers and live counts.
The former Date/Author/Status grouping modes are demoted to a **secondary sort applied
within each section**.

The motivation (confirmed during design) is two-fold:

1. **The separation must always hold** — it is structural, never toggled away by a sort
   choice.
2. **The distinction must read as two places** — two faint text headers in one scroll
   are not enough; the sections get a stronger visual treatment.

Both lists stay visible at once (shared scroll), so this is *not* a focus/one-at-a-time
toggle.

## Goals

- My Work / Review Requests is always the outer structure of the sidebar, in fixed order.
- Each section has a strong header: accent bar, title, live item count, disclosure chevron.
- Each section is independently collapsible; collapse state persists across launches.
- Within-section ordering remains controllable (Recent / By status / By author).
- Existing row content and behaviour (status dot, lifecycle badge, CI chips, context
  menu, selection, keyboard nav, delete) are untouched.

## Non-goals (for now)

- Independent per-section scrolling / draggable divider (the "true split pane" — option B
  in design; rejected in favour of shared scroll + collapse).
- Side-by-side columns or a whole-app mode switch (rejected spatial arrangements).
- Hiding one section to focus on the other (the "focus" model — not wanted).
- Nested sub-group headers inside a section (Today/Yesterday buckets within My Work) —
  the date/author/status modes become a flat *sort*, not a sub-grouping.
- Re-designing the three detail panes (Claude / GitHub / Diff) — unchanged.

## Key decisions (decision log)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Split status | **Permanent structure**, not a grouping mode | Separation must always hold regardless of sort (design driver A) |
| 2 | Spatial arrangement | **Stacked in the one left sidebar** (vs side-by-side columns / app-mode switch) | Standard macOS source-list pattern; leaves horizontal width for the 3 panes |
| 3 | Scroll model | **Shared scroll + collapsible sections** (vs draggable independent panes) | Most native, smallest change; collapse handles the occasional long queue |
| 4 | Date/Author/Status modes | **Demote to a within-section sort** (vs nested sub-groups / drop) | Keeps the strong two-place split to one header level (design driver C) |
| 5 | `byCategory` enum case | **Removed** — it is now the layout, not a choice | A mode that is always-on is not a mode |
| 6 | Empty sections | **Always rendered** with a count and a faint placeholder | Structure must never shift position |
| 7 | Header treatment | Accent bar (blue = My Work, purple = Review Requests) + count + chevron | Reads as two distinct places (design driver C) |
| 8 | Collapse state | **Persisted in `Settings`** | Survives relaunch like the rest of sidebar prefs |

## Information architecture

```
Sidebar (always, fixed order):
  ▾ MY WORK · <count>          accent: blue
      <items where category ∈ {task, myPR}>   ordered by secondary sort
  ▾ REVIEW REQUESTS · <count>  accent: purple
      <items where category == reviewRequest> ordered by secondary sort
```

- Partition is derived live from `WorkItem.category(myLogin:)` — never stored (consistent
  with the reframe's "derived, never stored" principle).
- Both sections always render. An empty section shows its header (count `0`) and a faint
  "Nothing here yet" row; it does not disappear, so the other section never jumps.
- Section order is fixed: My Work first, Review Requests second.

### Secondary sort (within each section)

The toolbar "Group" menu becomes a **"Sort"** menu with three options applied *inside*
each section as a flat ordering:

| Sort | Order |
|---|---|
| **Recent** (default) | `addedAt` descending — today's behaviour |
| **By status** | PR state order (open → draft → merged → closed), then `addedAt` desc |
| **By author** | author login A→Z, then `addedAt` desc |

No nested headers: sorting reorders rows within the section only.

## Data model / Settings

```
Settings (additions)
  sidebarSort        SidebarSort     // .recent (default) | .byStatus | .byAuthor
  myWorkCollapsed    Bool            // default false
  reviewsCollapsed   Bool            // default false
```

- `SidebarGrouping` enum: **remove `.byCategory`**. The remaining cases are no longer a
  user-facing grouping; the type is either retired or repurposed as the `SidebarSort`
  enum (`recent` / `byStatus` / `byAuthor`, dropping `none`/`byDate` unless we keep date
  as `recent`). Implementation picks one; this spec names the new concept `SidebarSort`.
- `schemaVersion` bump on `Settings` if needed; missing fields decode to defaults.

### Migration

A persisted `Settings` may carry any of the old `sidebarGrouping` values:

- `byCategory`, `none`, `byDate`  → `sidebarSort = .recent`
- `byStatus`                      → `sidebarSort = .byStatus`
- `byAuthor`                      → `sidebarSort = .byAuthor`

Collapse flags default to `false` (both expanded) when absent.

## UI (ContentView)

- Remove the `sidebarGrouping == .none` flat-list branch and the `groupedReviews()`
  switch. Replace with a fixed two-section render.
- Each section is a collapsible header + body. Header is a custom row:
  `[accent bar] Title  …  count  [chevron]`. Toggling the chevron flips the persisted
  collapse flag.
- Section body is `ForEach(sortedItems(for: category))` reusing the existing
  `sidebarRow(for:)` verbatim (tags, selection, context menu unchanged).
- Toolbar: the "Group" menu becomes a "Sort" menu bound to `Settings.sidebarSort`.
- `NavigationSplitView`, detail pane, min widths, add/new-task toolbar items: unchanged.

## Error handling / edge cases

- **Empty section** — header with count `0` + faint placeholder; never removed.
- **Selection across collapse** — collapsing the section that holds the current selection
  keeps the selection valid (detail pane stays); expanding restores the row in place.
- **Migration of unknown old value** — any unrecognised `sidebarGrouping` falls back to
  `.recent`.
- **`myLogin` not yet fetched** — items with `prRef.authorLogin == nil` match-test against
  a nil login resolve to Review Requests (today's `category` behaviour); no crash.

## Testing (Swift Testing, `Core`)

- Partition: items split into My Work (`task`,`myPR`) vs Review Requests (`reviewRequest`)
  for a representative mixed set.
- Empty-section: a set with only review requests still yields a (count 0) My Work section.
- Secondary sort: `.recent` / `.byStatus` / `.byAuthor` order correctly within a section.
- Settings migration: each legacy `sidebarGrouping` value maps to the documented
  `sidebarSort`; collapse flags default to expanded.
- Settings round-trip: collapse flags + sort persist and decode.

UI render (pinned headers, chevron toggle) verified manually via build + launch, per the
project's SwiftUI convention.

## Open questions

- Keep a literal **Recent** label vs **By date** for the default sort (cosmetic).
- Whether to retire the `SidebarGrouping` type entirely or rename it to `SidebarSort`
  (implementation detail; both are fine).
