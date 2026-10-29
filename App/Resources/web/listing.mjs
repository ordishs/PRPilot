// Pure list logic for the phone client. Each rule mirrors the Mac sidebar, so the same
// pills, search and sort give the same rows on both. No DOM and no imports, so node can
// test it directly.

export const SECTION_ORDER = ['myWork', 'reviewRequests', 'issues']

export const SECTION_TITLES = {
  myWork: 'My Work',
  reviewRequests: 'Review Requests',
  issues: 'Issues',
}

/// Every item with the section it came from attached.
export function flatten(snapshot) {
  return snapshot.sections.flatMap((section) =>
    section.items.map((item) => ({ ...item, section: section.kind }))
  )
}

export function findItem(snapshot, id) {
  for (const section of snapshot.sections) {
    const found = section.items.find((item) => item.id === id)
    if (found) return found
  }
  return null
}

/// Mirrors `sidebarItemMatches`. Pills inside one group widen the result; the two groups
/// narrow each other. Hide parked is an exclusion, so it runs first and it wins.
export function matchesFilters(item, selection) {
  if (selection.hideParked && item.isParked) return false
  if (selection.signals.size > 0 && !item.signals.some((key) => selection.signals.has(key))) {
    return false
  }
  if (
    selection.resources.size > 0 &&
    !item.resources.some((key) => selection.resources.has(key))
  ) {
    return false
  }
  return true
}

/// Mirrors the search half of `sidebarItemMatches`: title, owner/repo, author, head
/// branch, label and "#number", case-insensitive.
export function matchesQuery(item, query) {
  const needle = query.trim().toLowerCase()
  if (needle === '') return true
  const haystacks = [
    item.title,
    `${item.owner ?? ''}/${item.repo ?? ''}`,
    item.author ?? '',
    item.headBranch ?? '',
    item.label ?? '',
    item.number != null ? `#${item.number}` : '',
  ]
  return haystacks.some((field) => field.toLowerCase().includes(needle))
}

function addedAtMillis(item) {
  const at = new Date(item.addedAt).getTime()
  return Number.isNaN(at) ? 0 : at
}

/// Mirrors `sortWorkItems`. Every order falls back to newest first.
export function sortItems(items, sort) {
  const newestFirst = (a, b) => addedAtMillis(b) - addedAtMillis(a)
  const copy = items.slice()

  if (sort === 'byStatus') {
    return copy.sort((a, b) => a.statusRank - b.statusRank || newestFirst(a, b))
  }
  if (sort === 'byAuthor') {
    return copy.sort(
      (a, b) =>
        (a.author ?? '').localeCompare(b.author ?? '', undefined, { sensitivity: 'base' }) ||
        newestFirst(a, b)
    )
  }
  if (sort === 'byNumber') {
    // Highest first, like Recent. An item with no number sinks to the bottom.
    return copy.sort((a, b) => {
      const an = a.number ?? -Infinity
      const bn = b.number ?? -Infinity
      if (an !== bn) return an === -Infinity ? 1 : bn === -Infinity ? -1 : bn - an
      return newestFirst(a, b)
    })
  }
  return copy.sort(newestFirst)
}

/// The rows of one section after search, pills and sort.
export function visibleItems(snapshot, sectionKind, query, selection, sort) {
  const section = snapshot.sections.find((candidate) => candidate.kind === sectionKind)
  const items = section ? section.items : []
  return sortItems(
    items.filter((item) => matchesFilters(item, selection) && matchesQuery(item, query)),
    sort
  )
}

/// Tab counts follow the search and the pills, like the Mac section headers do.
export function sectionCounts(snapshot, query, selection) {
  const counts = {}
  for (const kind of SECTION_ORDER) {
    const section = snapshot.sections.find((candidate) => candidate.kind === kind)
    const items = section ? section.items : []
    counts[kind] = items.filter(
      (item) => matchesFilters(item, selection) && matchesQuery(item, query)
    ).length
  }
  return counts
}

/// Pill counts are over every item, whatever is selected, like the Mac pills.
export function pillCounts(snapshot) {
  const signals = {}
  const resources = {}
  let parked = 0

  for (const item of flatten(snapshot)) {
    for (const key of item.signals) signals[key] = (signals[key] ?? 0) + 1
    for (const key of item.resources) resources[key] = (resources[key] ?? 0) + 1
    if (item.isParked) parked += 1
  }
  return { signals, resources, parked }
}

export function emptySelection(hideParked = false) {
  return { signals: new Set(), resources: new Set(), hideParked }
}

export function toggled(set, key) {
  const next = new Set(set)
  if (next.has(key)) {
    next.delete(key)
  } else {
    next.add(key)
  }
  return next
}

export function selectionIsEmpty(selection) {
  return selection.signals.size === 0 && selection.resources.size === 0 && !selection.hideParked
}
