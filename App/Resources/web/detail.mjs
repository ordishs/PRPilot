const EMPTY = {
  pane: 'github',
  paneState: 'idle',
  paneMessage: null,
  runLabel: null,
  rebase: null,
  agentChoice: null,
  agentKey: 'claudeCode',
  agentTabs: [],
  canHandOver: false,
  sessionID: null,
  canClearAgentBadge: false,
  canClearAuthorBadge: false,
  canClearLimit: false,
}

export function detailOf(item) {
  return { ...EMPTY, ...(item.detail || {}) }
}

/// GitHub first, then one tab per agent that holds a session. A disabled item has no
/// agent to show.
export function detailTabs(item) {
  if (item.isDisabled) return ['github']
  return ['github', ...detailOf(item).agentTabs]
}

/// The tab to show: the one just chosen if it still exists, else the Mac's remembered
/// pane. The agent the Mac is running counts as present even before its session is
/// written down, so a tab just added from "+" does not flicker back to GitHub.
export function activeTab(item, chosen) {
  if (item.isDisabled) return 'github'
  const detail = detailOf(item)
  if (chosen === 'github') return 'github'
  if (chosen && (detail.agentTabs.includes(chosen) || chosen === detail.agentKey)) return chosen
  return detail.pane === 'claude' ? detail.agentKey : 'github'
}

/// Agents the "+" menu offers: every configured agent without a tab, each starting a
/// session through `setAgent`, which resumes the agent's own session when it has one.
export function addableAgents(snapshot, item) {
  if (item.isDisabled) return []
  const { agentTabs } = detailOf(item)
  return snapshot.listing.agents
    .filter((agent) => !agentTabs.includes(agent.key))
    .map((agent) => ({
      key: agent.key,
      label: agent.label,
      command: { type: 'setAgent', id: item.id, agent: agent.key },
    }))
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
