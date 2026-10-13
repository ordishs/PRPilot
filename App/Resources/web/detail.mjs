const EMPTY = {
  pane: 'github',
  paneState: 'idle',
  paneMessage: null,
  runLabel: null,
  rebase: null,
  agentChoice: null,
  agentKey: 'claudeCode',
  canHandOver: false,
  sessionID: null,
  canClearAgentBadge: false,
  canClearAuthorBadge: false,
  canClearLimit: false,
}

export function detailOf(item) {
  return { ...EMPTY, ...(item.detail || {}) }
}

export function availablePanes(item) {
  return item.isDisabled ? ['github'] : ['claude', 'github']
}

export function activePane(item, chosen) {
  const panes = availablePanes(item)
  if (chosen && panes.includes(chosen)) return chosen
  return panes.includes(detailOf(item).pane) ? detailOf(item).pane : 'github'
}

export function needsSession(item) {
  return !item.isDisabled && detailOf(item).paneState === 'idle'
}

function label(listing, key) {
  return listing.agents.find((agent) => agent.key === key)?.label ?? key
}

export function agentOptions(snapshot, item) {
  const { listing } = snapshot
  const detail = detailOf(item)
  const confirm = item.agent?.status === 'working'
    ? 'The agent is working. Switching ends its live session.'
    : null
  const command = (agent) => ({ type: 'setAgent', id: item.id, agent })

  return [
    {
      key: 'default',
      label: `Default (${label(listing, listing.defaultAgent)})`,
      checked: detail.agentChoice === null,
      command: command(null),
      confirm,
    },
    ...listing.agents.map((agent) => ({
      key: agent.key,
      label: agent.label,
      checked: detail.agentChoice === agent.key,
      command: command(agent.key),
      confirm,
    })),
  ]
}

export function itemActions(snapshot, item) {
  const { listing } = snapshot
  const detail = detailOf(item)
  const id = item.id
  const actions = []

  actions.push({ key: 'label', label: item.label ? 'Edit Label…' : 'Add Label…', prompt: { type: 'setLabel', id, label: item.label || '' } })
  if (item.label) {
    actions.push({ key: 'clearLabel', label: 'Clear Label', command: { type: 'setLabel', id, label: null } })
  }
  if (detail.canClearAgentBadge) {
    actions.push({ key: 'clearAgentBadge', label: 'Clear Agent Badge', command: { type: 'clearWaiting', id } })
  }
  if (item.kind === 'issue') {
    actions.push({
      key: 'setStatus',
      label: 'Set Status',
      choices: [
        ...listing.issueStatuses.map((status) => ({
          label: status.label,
          command: { type: 'setIssueStatus', id, status: status.key },
        })),
        { label: 'Clear (Auto)', command: { type: 'setIssueStatus', id, status: null } },
      ],
    })
  }
  if (detail.sessionID) {
    actions.push({ key: 'copySession', label: 'Copy Session ID', copy: detail.sessionID })
    actions.push({ key: 'clearSession', label: 'Clear Session', command: { type: 'clearSession', id } })
  }
  if (detail.canClearAuthorBadge) {
    actions.push({ key: 'clearAuthorBadge', label: 'Clear Author Badge', command: { type: 'markAuthorUpdateSeen', id } })
  }
  if (detail.canClearLimit) {
    actions.push({ key: 'clearLimit', label: 'Clear Limit Badge', command: { type: 'clearAgentLimit', id } })
  }
  if (detail.canHandOver) {
    actions.push({
      key: 'handOver',
      label: `Hand over to ${label(listing, listing.failoverAgent)}…`,
      command: { type: 'handOver', id },
    })
  }
  actions.push({ key: 'refresh', label: 'Refresh from GitHub', command: { type: 'refreshItem', id } })
  actions.push({
    key: 'toggleDisabled',
    label: item.isDisabled ? 'Enable' : 'Disable',
    command: { type: 'setDisabled', id, disabled: !item.isDisabled },
  })
  actions.push({
    key: 'remove',
    label: 'Remove from List',
    danger: true,
    confirm: 'Remove this item? Its worktree is deleted from the Mac.',
    command: { type: 'removeItem', id },
  })

  return actions
}
