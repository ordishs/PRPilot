import {
  html,
  render,
  useState,
  useEffect,
  useCallback,
  useMemo,
} from '/vendor/preact-htm.mjs'

const TOKEN_KEY = 'prpilot.token'

const GROUP_TITLES = {
  needsYou: 'Needs you',
  running: 'Running',
  queued: 'Queued',
  idle: 'Idle',
}

// Fixed order, so the bar does not reshuffle as counts change.
const TAB_ORDER = ['needsYou', 'running', 'queued', 'idle']

// Shorter labels for the bar itself — four full titles do not fit a phone.
const TAB_LABELS = {
  needsYou: 'Needs you',
  running: 'Running',
  queued: 'Queued',
  idle: 'Idle',
}

const EMPTY_MESSAGES = {
  needsYou: 'Nothing needs you.',
  running: 'No agent is running.',
  queued: 'Nothing is queued.',
  idle: 'Nothing idle.',
}

function loadToken() {
  try {
    const fromUrl = new URLSearchParams(location.search).get('token')
    if (fromUrl) {
      localStorage.setItem(TOKEN_KEY, fromUrl)
      history.replaceState(null, '', location.pathname)
      return fromUrl
    }
    return localStorage.getItem(TOKEN_KEY)
  } catch {
    // Private browsing can throw on any storage access. A pasted token still works
    // for the life of the tab.
    return new URLSearchParams(location.search).get('token')
  }
}

function saveToken(value) {
  try {
    localStorage.setItem(TOKEN_KEY, value)
  } catch {
    // Not fatal — the token stays in memory for this tab.
  }
}

/// Subscribes to the snapshot stream. EventSource reconnects on its own, and the first
/// event after a reconnect is a full snapshot, so there is nothing to reconcile.
function useSnapshot(token) {
  const [snapshot, setSnapshot] = useState(null)
  const [connected, setConnected] = useState(false)
  const [rejected, setRejected] = useState(false)

  useEffect(() => {
    if (!token) return

    // EventSource cannot set an Authorization header, so the token travels in the query
    // string for this one route. The server accepts it that way on /api/events only.
    const source = new EventSource(`/api/events?token=${encodeURIComponent(token)}`)

    source.onopen = () => {
      setConnected(true)
      setRejected(false)
    }
    source.onmessage = (event) => {
      setSnapshot(JSON.parse(event.data))
      setConnected(true)
      setRejected(false)
    }
    source.onerror = () => {
      setConnected(false)
      // A stream that never opened is almost always a bad token. One that opened and
      // dropped is a tunnel blip, and EventSource will retry by itself.
      setRejected((wasRejected) => wasRejected || source.readyState === EventSource.CLOSED)
    }

    return () => source.close()
  }, [token])

  return { snapshot, connected, rejected }
}

const PRIMARY_LABELS = {
  clearAgentLimit: 'Clear limit and resume',
  clearWaiting: 'Mark as answered',
  markAuthorUpdateSeen: 'Mark update seen',
}

function newCommandID() {
  if (crypto.randomUUID) return crypto.randomUUID()
  return `c-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/// Commands are never applied optimistically. `startSession` takes real time on the Mac,
/// and a guess the stream later contradicts is worse than a spinner.
async function sendCommand(token, command) {
  const response = await fetch('/api/command', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ commandID: newCommandID(), command }),
  })

  if (!response.ok) {
    throw new Error(`Command failed (${response.status})`)
  }
  return response.json()
}

async function fetchTranscript(token, id, limit = 80) {
  const response = await fetch(
    `/api/transcript?id=${encodeURIComponent(id)}&limit=${limit}`,
    { headers: { authorization: `Bearer ${token}` } }
  )
  if (!response.ok) throw new Error(`Transcript failed (${response.status})`)
  return response.json()
}

function clockTime(iso) {
  if (!iso) return ''
  const at = new Date(iso)
  return Number.isNaN(at.getTime())
    ? ''
    : at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

/// The conversation for one item, read from the agent's transcript on disk.
///
/// Polls rather than streaming: the snapshot stream carries the queue, and a transcript is
/// far larger and only wanted while one item is open.
function Conversation({ item, token, onError }) {
  const [transcript, setTranscript] = useState(null)
  const [draft, setDraft] = useState('')
  const [sending, setSending] = useState(false)

  const load = useCallback(async () => {
    try {
      setTranscript(await fetchTranscript(token, item.id))
    } catch (error) {
      onError(String(error.message || error))
    }
  }, [token, item.id, onError])

  useEffect(() => {
    load()
    const timer = setInterval(load, 4000)
    return () => clearInterval(timer)
  }, [load])

  const send = async () => {
    const text = draft.trim()
    if (!text) return
    setSending(true)
    try {
      const result = await sendCommand(token, { type: 'sendPrompt', id: item.id, text })
      if (result.status === 'rejected') {
        onError(result.message || 'The Mac refused that.')
      } else {
        setDraft('')
        // The agent needs a moment to write its turn before it appears.
        setTimeout(load, 1200)
      }
    } catch (error) {
      onError(String(error.message || error))
    } finally {
      setSending(false)
    }
  }

  if (!transcript) {
    return html`<p class="conv-note">Loading the conversation…</p>`
  }

  if (!transcript.available) {
    return html`<p class="conv-note">${transcript.note || 'No conversation yet.'}</p>`
  }

  return html`
    <div class="conv">
      ${transcript.truncated &&
        html`<p class="conv-note">Showing the most recent turns. The rest is on the Mac.</p>`}
      ${transcript.turns.map(
        (turn, index) => html`
          <div key=${`${turn.at}-${index}`} class=${`turn ${turn.role}`}>
            <div class="turn-head">
              ${turn.role === 'user' ? 'You' : transcript.agent} · ${clockTime(turn.at)}
            </div>
            <div class="turn-text">${turn.text}</div>
          </div>
        `
      )}
      <div class="reply">
        <textarea
          rows="2"
          value=${draft}
          placeholder="Reply to ${transcript.agent}…"
          onInput=${(event) => setDraft(event.target.value)}
        ></textarea>
        <button disabled=${sending || draft.trim() === ''} onClick=${send}>
          ${sending ? '…' : 'Send'}
        </button>
      </div>
    </div>
  `
}

function findItem(snapshot, id) {
  for (const group of snapshot.groups) {
    const found = group.items.find((item) => item.id === id)
    if (found) return found
  }
  return null
}

function elapsed(seconds) {
  if (seconds == null) return null
  if (seconds < 90) return `${seconds}s`
  const minutes = Math.round(seconds / 60)
  if (minutes < 90) return `${minutes}m`
  return `${Math.round(minutes / 60)}h`
}

const SORTS = [
  { key: 'recent', label: 'Recent activity' },
  { key: 'author', label: 'Author' },
  { key: 'number', label: 'Number' },
]

/// Short relative age. A phone row has no space for a date, and "14m" answers the
/// question a timestamp would.
function ago(iso) {
  if (!iso) return ''
  const then = new Date(iso).getTime()
  if (Number.isNaN(then)) return ''
  const seconds = Math.max(0, (Date.now() - then) / 1000)
  if (seconds < 90) return `${Math.round(seconds)}s`
  const minutes = seconds / 60
  if (minutes < 90) return `${Math.round(minutes)}m`
  const hours = minutes / 60
  if (hours < 36) return `${Math.round(hours)}h`
  return `${Math.round(hours / 24)}d`
}

/// Matches the fields you would actually search by: number, title, author, repo and
/// label. Case-insensitive, and a bare number matches the PR number.
function matches(item, query) {
  if (!query) return true
  const needle = query.toLowerCase()
  return [
    item.title,
    item.author,
    item.repo,
    item.owner,
    item.label,
    item.issueStatus,
    item.number != null ? String(item.number) : '',
    item.number != null ? `#${item.number}` : '',
  ].some((field) => field && String(field).toLowerCase().includes(needle))
}

function sortItems(items, sort) {
  const copy = items.slice()
  if (sort === 'author') {
    return copy.sort((a, b) =>
      (a.author || '~').localeCompare(b.author || '~') ||
      (b.number || 0) - (a.number || 0)
    )
  }
  if (sort === 'number') {
    return copy.sort((a, b) => (b.number || 0) - (a.number || 0))
  }
  // Recent activity. Items with no timestamp sort last rather than to the top.
  return copy.sort(
    (a, b) =>
      new Date(b.lastActivityAt || 0).getTime() - new Date(a.lastActivityAt || 0).getTime()
  )
}

/// Every item, with the group it came from attached, so a search result can say where
/// it lives without the caller re-scanning the snapshot.
function flatten(snapshot) {
  return snapshot.groups.flatMap((group) =>
    group.items.map((item) => ({ ...item, group: group.kind }))
  )
}

function itemCount(snapshot) {
  return snapshot.groups.reduce((total, group) => total + group.items.length, 0)
}

/// The server drops empty groups, so a tab with no items has no entry at all.
/// Every tab still needs a count, hence the zero default.
function countsByGroup(snapshot) {
  const counts = { needsYou: 0, running: 0, queued: 0, idle: 0 }
  for (const group of snapshot.groups) {
    counts[group.kind] = group.items.length
  }
  return counts
}

function itemsForTab(snapshot, tab) {
  const group = snapshot.groups.find((candidate) => candidate.kind === tab)
  return group ? group.items : []
}

function subtitle(item) {
  const where = item.repo ? `${item.repo} #${item.number}` : 'task'
  return item.label ? `${where} · ${item.label}` : where
}

function Row({ item, onOpen, showGroup }) {
  const dim = item.isDisabled || !item.attentionReason
  const meta = [
    item.repo ? `${item.repo} #${item.number}` : 'task',
    item.author,
    ago(item.lastActivityAt),
    item.label,
  ]
    .filter(Boolean)
    .join(' · ')

  return html`
    <button class=${dim ? 'row dim' : 'row'} onClick=${() => onOpen(item.id)}>
      <div class="row-title">${item.title}</div>
      ${item.attentionReason &&
        html`<div class="row-reason">${item.attentionReason}</div>`}
      <div class="row-meta">
        ${showGroup &&
          html`<span class=${`row-group ${item.group}`}>${GROUP_TITLES[item.group]}</span>`}
        ${meta}
      </div>
      ${item.badges.length > 0 &&
        html`
          <div class="row-badges">
            ${item.badges.map(
              (badge) => html`
                <span key=${badge.text} class=${`badge ${badge.tone}`} title=${badge.help}>
                  ${badge.text}
                </span>
              `
            )}
          </div>
        `}
    </button>
  `
}

function FilterBar({ query, onQuery, sort, onSort }) {
  return html`
    <div class="filterbar">
      <div class="search">
        <input
          type="search"
          value=${query}
          placeholder="Search number, title, author, repo"
          autocapitalize="off"
          autocorrect="off"
          spellcheck="false"
          onInput=${(event) => onQuery(event.target.value)}
        />
        ${query &&
          html`<button class="clear" onClick=${() => onQuery('')} aria-label="Clear search">✕</button>`}
      </div>
      <select class="sort" value=${sort} onChange=${(event) => onSort(event.target.value)}>
        ${SORTS.map(
          (option) => html`<option key=${option.key} value=${option.key}>${option.label}</option>`
        )}
      </select>
    </div>
  `
}

function Tabs({ counts, tab, onSelect }) {
  return html`
    <nav class="tabs" role="tablist">
      ${TAB_ORDER.map(
        (kind) => html`
          <button
            key=${kind}
            role="tab"
            aria-selected=${tab === kind}
            class=${`tab ${kind}${tab === kind ? ' active' : ''}`}
            onClick=${() => onSelect(kind)}
          >
            <span class="tab-label">${TAB_LABELS[kind]}</span>
            <span class=${`tab-count${kind === 'needsYou' && counts[kind] > 0 ? ' urgent' : ''}`}>
              ${counts[kind]}
            </span>
          </button>
        `
      )}
    </nav>
  `
}

/// Searching deliberately ignores the tabs. You rarely know which group the item you are
/// hunting for landed in, so a search that only looked in the current tab would usually
/// find nothing.
function List({ snapshot, tab, query, sort, onOpen }) {
  const searching = query.trim() !== ''
  const items = searching
    ? sortItems(flatten(snapshot).filter((item) => matches(item, query.trim())), sort)
    : sortItems(itemsForTab(snapshot, tab), sort)

  return html`
    <div class="list">
      ${snapshot.warnings.length > 0 &&
        html`<div class="warnings">${snapshot.warnings.join(' · ')}</div>`}
      ${searching &&
        html`<p class="result-count">
          ${items.length} ${items.length === 1 ? 'match' : 'matches'} across all groups
        </p>`}
      ${items.length === 0
        ? html`<p class="empty">
            ${searching ? `Nothing matches "${query.trim()}".` : EMPTY_MESSAGES[tab]}
          </p>`
        : items.map(
            (item) => html`
              <${Row} key=${item.id} item=${item} onOpen=${onOpen} showGroup=${searching} />
            `
          )}
    </div>
  `
}

function TokenPrompt({ onToken, failed }) {
  const [value, setValue] = useState('')

  return html`
    <div class="prompt">
      <h1>PR Pilot</h1>
      <p>
        Paste the pairing token from Settings → Remote on the Mac, or scan its QR code.
      </p>
      ${failed && html`<p class="failed">That token was refused. Check it and try again.</p>`}
      <input
        value=${value}
        onInput=${(event) => setValue(event.target.value)}
        placeholder="token"
        autocapitalize="off"
        autocorrect="off"
        spellcheck="false"
      />
      <button onClick=${() => value.trim() && onToken(value.trim())}>Connect</button>
    </div>
  `
}

function Detail({ item, token, onError, onNotice }) {
  const [busy, setBusy] = useState(null)
  const [moreOpen, setMoreOpen] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)
  const [showConversation, setShowConversation] = useState(false)

  const run = async (command, key) => {
    setBusy(key)
    try {
      const result = await sendCommand(token, command)
      if (result.status === 'rejected') {
        onError(result.message || 'The Mac refused that command.')
      } else {
        // Some commands succeed and still have something to say — a handover names
        // the agent that picked the work up.
        if (result.message) onNotice(result.message)
        setMoreOpen(false)
        setConfirmRemove(false)
      }
    } catch (error) {
      onError(String(error.message || error))
    } finally {
      setBusy(null)
    }
  }

  const freshSession = { type: 'startSession', id: item.id, forceFresh: true }
  const primaryCommand = item.primaryCommand || freshSession
  const primaryLabel = item.primaryCommand
    ? PRIMARY_LABELS[item.primaryCommand.type] || 'Run'
    : 'Fresh session'

  const stats = [elapsed(item.agent?.elapsedSeconds), item.agent?.usedPercent != null ? `${item.agent.usedPercent}%` : null]
    .filter(Boolean)
    .join(' · ')

  return html`
    <div class="detail">
      <h1 class="detail-title">${item.title}</h1>
      <div class="detail-meta">
        ${[item.repo ? `${item.repo} #${item.number}` : 'task', item.author, item.headBranch]
          .filter(Boolean)
          .join(' · ')}
      </div>

      ${item.attentionReason &&
        html`<div class="banner">${item.attentionReason}</div>`}

      ${item.agent &&
        html`
          <div class="card">
            <div class="card-head">
              <span class="agent-kind">${item.agent.kind} · ${item.agent.status}</span>
              ${stats && html`<span class="agent-stat">${stats}</span>`}
            </div>
            ${item.agent.verdict && html`<p class="verdict">${item.agent.verdict}</p>`}
          </div>
        `}

      ${item.badges.length > 0 &&
        html`
          <div class="label">State</div>
          <div class="badges">
            ${item.badges.map(
              (badge) => html`
                <span key=${badge.text} class=${`badge ${badge.tone}`}>${badge.text}</span>
              `
            )}
          </div>
          <div class="badge-help">
            ${item.badges.map((badge) => html`<div key=${badge.text}>${badge.text} — ${badge.help}</div>`)}
          </div>
        `}

      <div class="label">Conversation</div>
      ${showConversation
        ? html`<${Conversation} item=${item} token=${token} onError=${onError} />`
        : html`
            <button class="conv-open" onClick=${() => setShowConversation(true)}>
              Show the ${item.agent ? item.agent.kind : 'agent'} conversation
            </button>
          `}

      <div class="label">Branch</div>
      <div class="facts">
        base ${item.baseBranch} · ↑${item.ahead} ↓${item.behind}
        ${item.localChanges > 0 ? ` · ${item.localChanges} local` : ''}
        ${item.issueStatus ? ` · ${item.issueStatus}` : ''}
      </div>

      ${item.url &&
        html`<a class="external" href=${item.url} target="_blank" rel="noreferrer">Open on GitHub ↗</a>`}

      <div class="sheet-spacer"></div>

      <div class="sheet">
        <div class="grabber"></div>
        <button
          class="primary"
          disabled=${busy !== null}
          onClick=${() => run(primaryCommand, 'primary')}
        >
          ${busy === 'primary' ? 'Working…' : primaryLabel}
        </button>

        <div class="sheet-row">
          <button disabled=${busy !== null} onClick=${() => run(freshSession, 'fresh')}>
            ${busy === 'fresh' ? '…' : item.agent ? 'Restart fresh' : 'Fresh session'}
          </button>
          <button
            disabled=${busy !== null}
            onClick=${() => run({ type: 'handOver', id: item.id }, 'handover')}
          >
            ${busy === 'handover' ? '…' : 'Hand over'}
          </button>
          <button class="more" onClick=${() => setMoreOpen(!moreOpen)}>•••</button>
        </div>

        ${moreOpen &&
          html`
            <div class="more-menu">
              <button
                disabled=${busy !== null}
                onClick=${() => run({ type: 'refreshItem', id: item.id }, 'refresh')}
              >
                ${busy === 'refresh' ? '…' : 'Refresh from GitHub'}
              </button>
              <button
                disabled=${busy !== null}
                onClick=${() =>
                  run({ type: 'setDisabled', id: item.id, disabled: !item.isDisabled }, 'disable')}
              >
                ${busy === 'disable' ? '…' : item.isDisabled ? 'Enable' : 'Disable'}
              </button>
              ${confirmRemove
                ? html`
                    <button
                      class="danger"
                      disabled=${busy !== null}
                      onClick=${() => run({ type: 'removeItem', id: item.id }, 'remove')}
                    >
                      ${busy === 'remove' ? '…' : 'Really remove — deletes the worktree'}
                    </button>
                  `
                : html`
                    <button class="danger" onClick=${() => setConfirmRemove(true)}>
                      Remove from list
                    </button>
                  `}
            </div>
          `}
      </div>
    </div>
  `
}

function App() {
  const [token, setToken] = useState(loadToken)
  const [openID, setOpenID] = useState(null)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  // Always opens on Needs you. The one question worth answering on picking the
  // phone up is "is anything stuck?", so it is never hidden behind a stale tab.
  const [tab, setTab] = useState('needsYou')
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState('recent')
  const { snapshot, connected, rejected } = useSnapshot(token)

  const pair = useCallback((value) => {
    saveToken(value)
    setToken(value)
  }, [])

  const open = useMemo(
    () => (snapshot && openID ? findItem(snapshot, openID) : null),
    [snapshot, openID]
  )

  // An item can vanish while its detail screen is open — removed here, or removed at the
  // Mac. Fall back to the list rather than rendering nothing.
  useEffect(() => {
    if (openID && snapshot && !open) setOpenID(null)
  }, [openID, snapshot, open])

  if (!token) {
    return html`<${TokenPrompt} onToken=${pair} failed=${false} />`
  }

  if (rejected && !snapshot) {
    return html`<${TokenPrompt} onToken=${pair} failed=${true} />`
  }

  if (!snapshot) {
    return html`<div class="prompt"><p>Connecting…</p></div>`
  }

  return html`
    <div class="app">
      <!-- Everything pinned lives here. One sticky container clears the status bar
           once, and the back button can never scroll out of reach. -->
      <div class="chrome">
        ${!connected && html`<div class="offline">Reconnecting…</div>`}
        ${error && html`<div class="error" onClick=${() => setError(null)}>${error}</div>`}
        ${notice && html`<div class="notice" onClick=${() => setNotice(null)}>${notice}</div>`}
        ${open
          ? html`
              <div class="detail-bar">
                <button class="back" onClick=${() => setOpenID(null)}>‹ Back</button>
                <span class="detail-bar-title">${open.repo ? `${open.repo} #${open.number}` : 'task'}</span>
              </div>
            `
          : html`
              <header class="bar">
                <span class="brand">PR Pilot</span>
                <span class="count">${itemCount(snapshot)} items</span>
                <!-- Installed to the home screen there is no browser chrome, so no way to
                     reload and pick up a new client. This is it. -->
                <button
                  class="reload"
                  aria-label="Reload the app"
                  onClick=${() => location.reload()}
                >⟳</button>
              </header>
              <${FilterBar} query=${query} onQuery=${setQuery} sort=${sort} onSort=${setSort} />
              ${query.trim() === '' &&
                html`<${Tabs} counts=${countsByGroup(snapshot)} tab=${tab} onSelect=${setTab} />`}
            `}
      </div>
      ${open
        ? html`
            <${Detail}
              item=${open}
              token=${token}
              onError=${setError}
              onNotice=${setNotice}
            />
          `
        : html`
            <${List}
              snapshot=${snapshot}
              tab=${tab}
              query=${query}
              sort=${sort}
              onOpen=${setOpenID}
            />
          `}
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
