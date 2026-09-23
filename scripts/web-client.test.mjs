// Tests for the phone client's list logic. Run with: node --test scripts/web-client.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  SECTION_ORDER,
  flatten,
  findItem,
  matchesFilters,
  matchesQuery,
  sortItems,
  visibleItems,
  sectionCounts,
  pillCounts,
  emptySelection,
  toggled,
  selectionIsEmpty,
} from '../App/Resources/web/listing.mjs'

function item(overrides = {}) {
  return {
    id: 'o/r#1',
    title: 'UTXO store: drop the legacy index path',
    owner: 'bsv-blockchain',
    repo: 'teranode',
    number: 944,
    author: 'icellan',
    headBranch: 'fix/centrifuge',
    label: null,
    signals: [],
    resources: [],
    isParked: false,
    addedAt: '2026-09-01T10:00:00Z',
    statusRank: 0,
    ...overrides,
  }
}

function selection({ signals = [], resources = [], hideParked = false } = {}) {
  return { signals: new Set(signals), resources: new Set(resources), hideParked }
}

function snapshot(myWork, reviewRequests, issues = []) {
  return {
    sections: [
      { kind: 'myWork', items: myWork },
      { kind: 'reviewRequests', items: reviewRequests },
      { kind: 'issues', items: issues },
    ],
  }
}

test('no selection keeps every item', () => {
  assert.equal(matchesFilters(item({ isParked: true }), emptySelection()), true)
})

test('signal pills widen each other: either signal keeps the item', () => {
  const pick = selection({ signals: ['agent', 'author'] })
  assert.equal(matchesFilters(item({ signals: ['author'] }), pick), true)
  assert.equal(matchesFilters(item({ signals: ['agent'] }), pick), true)
  assert.equal(matchesFilters(item({ signals: ['ciFailing'] }), pick), false)
  assert.equal(matchesFilters(item({ signals: [] }), pick), false)
})

test('signal and resource groups narrow each other', () => {
  const pick = selection({ signals: ['agent'], resources: ['session'] })
  assert.equal(matchesFilters(item({ signals: ['agent'], resources: ['session'] }), pick), true)
  assert.equal(matchesFilters(item({ signals: ['agent'], resources: ['worktree'] }), pick), false)
  assert.equal(matchesFilters(item({ signals: [], resources: ['session'] }), pick), false)
})

test('hide parked wins over a selected signal', () => {
  const pick = selection({ signals: ['agent'], hideParked: true })
  assert.equal(matchesFilters(item({ signals: ['agent'], isParked: true }), pick), false)
  assert.equal(matchesFilters(item({ signals: ['agent'], isParked: false }), pick), true)
})

test('search reads title, owner/repo, author, head branch, label and #number', () => {
  const subject = item({ label: 'perf' })
  for (const query of ['legacy', 'bsv-blockchain/teranode', 'ICELLAN', 'centrifuge', 'perf', '#944', '944']) {
    assert.equal(matchesQuery(subject, query), true, `expected "${query}" to match`)
  }
  assert.equal(matchesQuery(subject, 'nothing-like-this'), false)
  assert.equal(matchesQuery(subject, '   '), true)
})

test('search copes with a task that has no repo, number, author or branch', () => {
  const task = item({ owner: null, repo: null, number: null, author: null, headBranch: null })
  assert.equal(matchesQuery(task, 'legacy'), true)
  assert.equal(matchesQuery(task, '#'), false)
})

test('recent sorts newest first', () => {
  const older = item({ id: 'a', addedAt: '2026-09-01T10:00:00Z' })
  const newer = item({ id: 'b', addedAt: '2026-09-02T10:00:00Z' })
  assert.deepEqual(sortItems([older, newer], 'recent').map((i) => i.id), ['b', 'a'])
})

test('by status puts open before draft before merged before closed, newest first inside', () => {
  const items = [
    item({ id: 'closed', statusRank: 3 }),
    item({ id: 'draft', statusRank: 1 }),
    item({ id: 'open-old', statusRank: 0, addedAt: '2026-09-01T00:00:00Z' }),
    item({ id: 'open-new', statusRank: 0, addedAt: '2026-09-03T00:00:00Z' }),
    item({ id: 'merged', statusRank: 2 }),
  ]
  assert.deepEqual(
    sortItems(items, 'byStatus').map((i) => i.id),
    ['open-new', 'open-old', 'draft', 'merged', 'closed']
  )
})

test('by author sorts case-insensitively, no author first, newest first inside', () => {
  const items = [
    item({ id: 'zed', author: 'zed' }),
    item({ id: 'amy-old', author: 'Amy', addedAt: '2026-09-01T00:00:00Z' }),
    item({ id: 'amy-new', author: 'amy', addedAt: '2026-09-02T00:00:00Z' }),
    item({ id: 'nobody', author: null }),
  ]
  assert.deepEqual(
    sortItems(items, 'byAuthor').map((i) => i.id),
    ['nobody', 'amy-new', 'amy-old', 'zed']
  )
})

test('sorting does not reorder the array it was given', () => {
  const items = [item({ id: 'a', addedAt: '2026-09-01T00:00:00Z' }), item({ id: 'b', addedAt: '2026-09-02T00:00:00Z' })]
  sortItems(items, 'recent')
  assert.deepEqual(items.map((i) => i.id), ['a', 'b'])
})

test('a section shows only its own rows, filtered and sorted', () => {
  const snap = snapshot(
    [item({ id: 'mine' })],
    [
      item({ id: 'parked', isParked: true, addedAt: '2026-09-03T00:00:00Z' }),
      item({ id: 'waiting', signals: ['agent'], addedAt: '2026-09-02T00:00:00Z' }),
      item({ id: 'quiet', addedAt: '2026-09-01T00:00:00Z' }),
    ]
  )
  assert.deepEqual(
    visibleItems(snap, 'reviewRequests', '', selection({ hideParked: true }), 'recent').map((i) => i.id),
    ['waiting', 'quiet']
  )
  assert.deepEqual(
    visibleItems(snap, 'reviewRequests', '', selection({ signals: ['agent'] }), 'recent').map((i) => i.id),
    ['waiting']
  )
  assert.deepEqual(visibleItems(snap, 'issues', '', emptySelection(), 'recent'), [])
})

test('tab counts follow the search and the pills', () => {
  const snap = snapshot(
    [item({ id: 'mine', title: 'gateway tabs' })],
    [item({ id: 'a', isParked: true }), item({ id: 'b', title: 'gateway pills' })],
    [item({ id: 'c' })]
  )
  assert.deepEqual(sectionCounts(snap, '', emptySelection()), { myWork: 1, reviewRequests: 2, issues: 1 })
  assert.deepEqual(sectionCounts(snap, '', selection({ hideParked: true })), { myWork: 1, reviewRequests: 1, issues: 1 })
  assert.deepEqual(sectionCounts(snap, 'gateway', emptySelection()), { myWork: 1, reviewRequests: 1, issues: 0 })
})

test('pill counts cover every item whatever is selected', () => {
  const snap = snapshot(
    [item({ signals: ['agent', 'dirty'], resources: ['worktree'] })],
    [item({ signals: ['agent'], resources: ['worktree', 'session'], isParked: true })]
  )
  assert.deepEqual(pillCounts(snap), {
    signals: { agent: 2, dirty: 1 },
    resources: { worktree: 2, session: 1 },
    parked: 1,
  })
})

test('flatten tags each item with its section, and findItem looks in every section', () => {
  const snap = snapshot([item({ id: 'mine' })], [item({ id: 'theirs' })])
  assert.deepEqual(flatten(snap).map((i) => [i.id, i.section]), [['mine', 'myWork'], ['theirs', 'reviewRequests']])
  assert.equal(findItem(snap, 'theirs').id, 'theirs')
  assert.equal(findItem(snap, 'gone'), null)
})

test('toggling adds then removes a key without touching the original set', () => {
  const start = new Set(['agent'])
  const added = toggled(start, 'author')
  assert.deepEqual([...added].sort(), ['agent', 'author'])
  assert.deepEqual([...toggled(added, 'agent')], ['author'])
  assert.deepEqual([...start], ['agent'])
})

test('a selection is empty only with no pills and hide parked off', () => {
  assert.equal(selectionIsEmpty(emptySelection()), true)
  assert.equal(selectionIsEmpty(emptySelection(true)), false)
  assert.equal(selectionIsEmpty(selection({ resources: ['web'] })), false)
})

test('the tab order is the Mac section order', () => {
  assert.deepEqual(SECTION_ORDER, ['myWork', 'reviewRequests', 'issues'])
})
