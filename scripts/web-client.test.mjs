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
import {
  detailOf,
  detailTabs,
  activeTab,
  addableAgents,
  needsSession,
  agentOptions,
  itemActions,
} from '../App/Resources/web/detail.mjs'

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

const listing = {
  agents: [
    { key: 'claudeCode', label: 'Claude Code' },
    { key: 'pi', label: 'pi' },
    { key: 'codex', label: 'Codex' },
  ],
  issueStatuses: [
    { key: 'onHold', label: 'On hold' },
    { key: 'done', label: 'Done' },
  ],
  defaultAgent: 'claudeCode',
  failoverAgent: 'codex',
}

const snap = { listing }

function detailItem(overrides = {}, detail = {}) {
  return item({
    id: 'o/r#1',
    kind: 'pr',
    url: 'https://github.com/o/r/pull/1',
    isDisabled: false,
    agent: null,
    detail: {
      pane: 'github',
      paneState: 'idle',
      agentKey: 'claudeCode',
      agentChoice: null,
      canHandOver: false,
      sessionID: null,
      canClearAgentBadge: false,
      canClearAuthorBadge: false,
      canClearLimit: false,
      ...detail,
    },
    ...overrides,
  })
}

test('sort by number puts the highest first and an item with no number last', () => {
  const items = [
    item({ id: 'task', number: null, addedAt: '2026-09-09T10:00:00Z' }),
    item({ id: 'n5', number: 5 }),
    item({ id: 'n40', number: 40 }),
    item({ id: 'n12', number: 12 }),
  ]
  assert.deepEqual(sortItems(items, 'byNumber').map((i) => i.id), ['n40', 'n12', 'n5', 'task'])
})

test('an item from an older server has an empty detail rather than none', () => {
  const old = detailItem()
  delete old.detail
  assert.equal(detailOf(old).pane, 'github')
  assert.equal(detailOf(old).paneState, 'idle')
})

test('a disabled item offers only the GitHub tab and stays on it', () => {
  const disabled = detailItem({ isDisabled: true }, { pane: 'claude', agentTabs: ['claudeCode'] })
  assert.deepEqual(detailTabs(disabled), ['github'])
  assert.equal(activeTab(disabled, null), 'github')
  assert.equal(activeTab(disabled, 'claudeCode'), 'github')
  assert.deepEqual(addableAgents(snap, disabled), [])
})

test('an item with no session has only the GitHub tab', () => {
  assert.deepEqual(detailTabs(detailItem({}, { agentTabs: [] })), ['github'])
})

test('each agent with a session is a tab after GitHub', () => {
  const pr = detailItem({}, { agentTabs: ['claudeCode', 'codex'], agentKey: 'codex', pane: 'claude' })
  assert.deepEqual(detailTabs(pr), ['github', 'claudeCode', 'codex'])
  assert.equal(activeTab(pr, null), 'codex')
  assert.equal(activeTab(pr, 'claudeCode'), 'claudeCode')
  assert.equal(activeTab(pr, 'github'), 'github')
})

test('a remembered GitHub pane opens on GitHub', () => {
  const pr = detailItem({}, { agentTabs: ['claudeCode'], agentKey: 'claudeCode', pane: 'github' })
  assert.equal(activeTab(pr, null), 'github')
})

test('a tab just added stays chosen before its session is written down', () => {
  const pr = detailItem({}, { agentTabs: ['claudeCode'], agentKey: 'pi', pane: 'github' })
  assert.equal(activeTab(pr, 'pi'), 'pi')
  assert.equal(activeTab(pr, 'codex'), 'github')
})

test('the add menu offers only agents without a tab', () => {
  const pr = detailItem({}, { agentTabs: ['claudeCode'] })
  const options = addableAgents(snap, pr)
  assert.deepEqual(options.map((o) => o.key), ['pi', 'codex'])
  assert.deepEqual(options[1].command, { type: 'setAgent', id: 'o/r#1', agent: 'codex' })
  assert.deepEqual(addableAgents(snap, detailItem({}, { agentTabs: ['claudeCode', 'pi', 'codex'] })), [])
})

test('the agent pane asks for a session only while it is idle', () => {
  assert.equal(needsSession(detailItem({}, { paneState: 'idle' })), true)
  assert.equal(needsSession(detailItem({}, { paneState: 'live' })), false)
  assert.equal(needsSession(detailItem({}, { paneState: 'preparing' })), false)
  assert.equal(needsSession(detailItem({}, { paneState: 'failed' })), false)
  assert.equal(needsSession(detailItem({ isDisabled: true }, { paneState: 'idle' })), false)
})

test('the agent menu marks the current choice and leads with the default', () => {
  const options = agentOptions(snap, detailItem({}, { agentChoice: 'pi', agentKey: 'pi' }))
  assert.deepEqual(options.map((o) => o.label), [
    'Default (Claude Code)',
    'Claude Code',
    'pi',
    'Codex',
  ])
  assert.deepEqual(options.map((o) => o.checked), [false, false, true, false])
  assert.deepEqual(options[0].command, { type: 'setAgent', id: 'o/r#1', agent: null })
  assert.deepEqual(options[3].command, { type: 'setAgent', id: 'o/r#1', agent: 'codex' })
})

test('a default-following item checks the Default entry', () => {
  const options = agentOptions(snap, detailItem())
  assert.equal(options[0].checked, true)
})

test('the agent menu asks for confirmation while the agent is working', () => {
  const working = detailItem({ agent: { kind: 'Claude Code', status: 'working' } })
  assert.ok(agentOptions(snap, working).every((o) => o.confirm))
  assert.ok(agentOptions(snap, detailItem()).every((o) => !o.confirm))
})

test('hand over appears in the actions only when the item can be handed over', () => {
  const blocked = detailItem({}, { canHandOver: true })
  const actions = itemActions(snap, blocked)
  assert.ok(actions.find((a) => a.key === 'handOver').label.includes('Codex'))
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'handOver'), undefined)
})

test('badge clears appear only when there is a badge to clear', () => {
  const none = itemActions(snap, detailItem()).map((a) => a.key)
  assert.ok(!none.includes('clearAgentBadge'))
  assert.ok(!none.includes('clearAuthorBadge'))
  assert.ok(!none.includes('clearLimit'))

  const all = itemActions(
    snap,
    detailItem({}, { canClearAgentBadge: true, canClearAuthorBadge: true, canClearLimit: true })
  ).map((a) => a.key)
  assert.ok(all.includes('clearAgentBadge'))
  assert.ok(all.includes('clearAuthorBadge'))
  assert.ok(all.includes('clearLimit'))
})

test('set status is offered for issues and not for pull requests', () => {
  const issue = itemActions(snap, detailItem({ kind: 'issue' }))
  const status = issue.find((a) => a.key === 'setStatus')
  assert.deepEqual(status.choices.map((c) => c.label), ['On hold', 'Done', 'Clear (Auto)'])
  assert.deepEqual(status.choices[2].command, { type: 'setIssueStatus', id: 'o/r#1', status: null })
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'setStatus'), undefined)
})

test('copy session id needs a session id', () => {
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'copySession'), undefined)
  const withSession = itemActions(snap, detailItem({}, { sessionID: 'abc' }))
  assert.equal(withSession.find((a) => a.key === 'copySession').copy, 'abc')
})

test('a fresh session is offered, with a confirmation, to any enabled item', () => {
  for (const detail of [{}, { sessionID: 'abc' }]) {
    const fresh = itemActions(snap, detailItem({}, detail)).find((a) => a.key === 'freshSession')
    assert.deepEqual(fresh.command, { type: 'startSession', id: 'o/r#1', forceFresh: true })
    assert.match(fresh.confirm, /cannot be resumed/)
  }
  const disabled = itemActions(snap, detailItem({ isDisabled: true }))
  assert.equal(disabled.find((a) => a.key === 'freshSession'), undefined)
  assert.equal(itemActions(snap, detailItem()).find((a) => a.key === 'clearSession'), undefined)
})

test('label edits prompt and clearing needs an existing label', () => {
  const unlabeled = itemActions(snap, detailItem())
  assert.equal(unlabeled.find((a) => a.key === 'label').label, 'Add Label…')
  assert.equal(unlabeled.find((a) => a.key === 'clearLabel'), undefined)

  const labeled = itemActions(snap, detailItem({ label: 'urgent' }))
  assert.equal(labeled.find((a) => a.key === 'label').label, 'Edit Label…')
  assert.deepEqual(labeled.find((a) => a.key === 'clearLabel').command, {
    type: 'setLabel',
    id: 'o/r#1',
    label: null,
  })
})

test('enable and disable flip with the item, and remove is destructive', () => {
  const on = itemActions(snap, detailItem())
  assert.deepEqual(on.find((a) => a.key === 'toggleDisabled').command, {
    type: 'setDisabled',
    id: 'o/r#1',
    disabled: true,
  })
  const off = itemActions(snap, detailItem({ isDisabled: true }))
  assert.equal(off.find((a) => a.key === 'toggleDisabled').label, 'Enable')
  assert.equal(on.find((a) => a.key === 'remove').danger, true)
  assert.equal(on.find((a) => a.key === 'remove').confirm.includes('worktree'), true)
})

test('no action ever names a git command', () => {
  const everything = itemActions(
    snap,
    detailItem(
      { kind: 'issue', label: 'x' },
      { canHandOver: true, sessionID: 's', canClearAgentBadge: true, canClearAuthorBadge: true, canClearLimit: true }
    )
  )
  const types = JSON.stringify(everything)
  for (const forbidden of ['push', 'rebase', 'continueRebase', 'abortRebase', 'discard']) {
    assert.ok(!types.toLowerCase().includes(`"type":"${forbidden.toLowerCase()}`))
  }
})
