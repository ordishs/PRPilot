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

function itemCount(snapshot) {
  return snapshot.groups.reduce((total, group) => total + group.items.length, 0)
}

function subtitle(item) {
  const where = item.repo ? `${item.repo} #${item.number}` : 'task'
  return item.label ? `${where} · ${item.label}` : where
}

function Row({ item, onOpen }) {
  const dim = item.isDisabled || !item.attentionReason

  return html`
    <button class=${dim ? 'row dim' : 'row'} onClick=${() => onOpen(item.id)}>
      <div class="row-title">${item.title}</div>
      ${item.attentionReason &&
        html`<div class="row-reason">${item.attentionReason}</div>`}
      <div class="row-meta">${subtitle(item)}</div>
    </button>
  `
}

function List({ snapshot, onOpen }) {
  if (snapshot.groups.length === 0) {
    return html`<p class="empty">Nothing in the queue.</p>`
  }

  return html`
    <div class="list">
      ${snapshot.warnings.length > 0 &&
        html`<div class="warnings">${snapshot.warnings.join(' · ')}</div>`}
      ${snapshot.groups.map(
        (group) => html`
          <section key=${group.kind}>
            <h2 class=${`group ${group.kind}`}>
              ${GROUP_TITLES[group.kind]} · ${group.items.length}
            </h2>
            ${group.items.map(
              (item) => html`<${Row} key=${item.id} item=${item} onOpen=${onOpen} />`
            )}
          </section>
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

function Detail({ item, token, onBack, onError }) {
  const [busy, setBusy] = useState(null)
  const [moreOpen, setMoreOpen] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)

  const run = async (command, key) => {
    setBusy(key)
    try {
      const result = await sendCommand(token, command)
      if (result.status === 'rejected') {
        onError(result.message || 'The Mac refused that command.')
      } else {
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
      <button class="back" onClick=${onBack}>‹ Back</button>

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
            ${busy === 'fresh' ? '…' : 'Fresh session'}
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
                onClick=${() => run({ type: 'clearSession', id: item.id }, 'clear')}
              >
                ${busy === 'clear' ? '…' : 'Clear session'}
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
      ${!connected && html`<div class="offline">Reconnecting…</div>`}
      ${error && html`<div class="error" onClick=${() => setError(null)}>${error}</div>`}
      ${open
        ? html`
            <${Detail}
              item=${open}
              token=${token}
              onBack=${() => setOpenID(null)}
              onError=${setError}
            />
          `
        : html`
            <header class="bar">
              <span class="brand">PR Pilot</span>
              <span class="count">${itemCount(snapshot)} items</span>
            </header>
            <${List} snapshot=${snapshot} onOpen=${setOpenID} />
          `}
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
