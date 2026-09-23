import {
  html,
  render,
  useState,
  useEffect,
  useCallback,
  useMemo,
} from '/vendor/preact-htm.mjs'
import {
  SECTION_ORDER,
  SECTION_TITLES,
  flatten,
  findItem,
  visibleItems,
  sectionCounts,
  pillCounts,
  emptySelection,
  toggled,
  selectionIsEmpty,
} from '/listing.mjs'

const TOKEN_KEY = 'prpilot.token'

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

function elapsed(seconds) {
  if (seconds == null) return null
  if (seconds < 90) return `${seconds}s`
  const minutes = Math.round(seconds / 60)
  if (minutes < 90) return `${minutes}m`
  return `${Math.round(minutes / 60)}h`
}

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

function Row({ item, onOpen }) {
  const dim = item.isDisabled
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
      <div class="row-meta">${meta}</div>
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

function FilterBar({ query, onQuery, sort, sorts, onSort }) {
  return html`
    <div class="filterbar">
      <div class="search">
        <input
          type="search"
          value=${query}
          placeholder="Search"
          autocapitalize="off"
          autocorrect="off"
          spellcheck="false"
          onInput=${(event) => onQuery(event.target.value)}
        />
        ${query &&
          html`<button class="clear" onClick=${() => onQuery('')} aria-label="Clear search">✕</button>`}
      </div>
      <select class="sort" value=${sort} onChange=${(event) => onSort(event.target.value)}>
        ${sorts.map(
          (option) => html`<option key=${option.key} value=${option.key}>${option.label}</option>`
        )}
      </select>
    </div>
  `
}

function Pill({ label, count, on, help, onToggle }) {
  return html`
    <button class=${on ? 'pill on' : 'pill'} title=${help} aria-pressed=${on} onClick=${onToggle}>
      ${label} <span class="pill-count">${count}</span>
    </button>
  `
}

/// The Mac's filter bar: signal pills, resource pills and Hide parked. One scrolling
/// strip, because thirteen pills do not fit a phone width.
function Pills({ listing, counts, selection, onSelection }) {
  return html`
    <div class="pills">
      ${listing.signalFilters.map(
        (option) => html`
          <${Pill}
            key=${option.key}
            label=${option.label}
            help=${option.help}
            count=${counts.signals[option.key] ?? 0}
            on=${selection.signals.has(option.key)}
            onToggle=${() =>
              onSelection({ ...selection, signals: toggled(selection.signals, option.key) })}
          />
        `
      )}
      ${listing.resourceFilters.map(
        (option) => html`
          <${Pill}
            key=${option.key}
            label=${option.label}
            help=${option.help}
            count=${counts.resources[option.key] ?? 0}
            on=${selection.resources.has(option.key)}
            onToggle=${() =>
              onSelection({ ...selection, resources: toggled(selection.resources, option.key) })}
          />
        `
      )}
      <${Pill}
        label="Hide parked"
        help="Hide PRs you approved that are now waiting on somebody else. One comes back as soon as the author pushes, replies, or asks you for another review."
        count=${counts.parked}
        on=${selection.hideParked}
        onToggle=${() => onSelection({ ...selection, hideParked: !selection.hideParked })}
      />
      ${!selectionIsEmpty(selection) &&
        html`<button class="pill clear-pills" onClick=${() => onSelection(emptySelection())}>
          Clear
        </button>`}
    </div>
  `
}

function Tabs({ counts, tab, onSelect }) {
  return html`
    <nav class="tabs" role="tablist">
      ${SECTION_ORDER.map(
        (kind) => html`
          <button
            key=${kind}
            role="tab"
            aria-selected=${tab === kind}
            class=${`tab${tab === kind ? ' active' : ''}`}
            onClick=${() => onSelect(kind)}
          >
            <span class="tab-label">${SECTION_TITLES[kind]}</span>
            <span class="tab-count">${counts[kind]}</span>
          </button>
        `
      )}
    </nav>
  `
}

/// One section at a time. Search and pills narrow every section, as on the Mac, so when
/// the open tab comes up empty the note says where the matches went.
function List({ snapshot, tab, query, selection, sort, counts, onOpen }) {
  const items = visibleItems(snapshot, tab, query, selection, sort)
  const elsewhere = SECTION_ORDER.filter((kind) => kind !== tab && counts[kind] > 0)
  const narrowed = query.trim() !== '' || !selectionIsEmpty(selection)

  return html`
    <div class="list">
      ${snapshot.warnings.length > 0 &&
        html`<div class="warnings">${snapshot.warnings.join(' · ')}</div>`}
      ${items.length === 0
        ? html`<p class="empty">
            ${narrowed ? 'Nothing here matches.' : `No items in ${SECTION_TITLES[tab]}.`}
            ${narrowed && elsewhere.length > 0 &&
              html`<br />${elsewhere
                .map((kind) => `${SECTION_TITLES[kind]}: ${counts[kind]}`)
                .join(' · ')}`}
          </p>`
        : items.map((item) => html`<${Row} key=${item.id} item=${item} onOpen=${onOpen} />`)}
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
  const [tab, setTab] = useState('reviewRequests')
  const [query, setQuery] = useState('')
  // Sort and Hide parked start from the Mac's settings, then belong to the phone. A tap
  // here never rearranges the Mac sidebar.
  const [sort, setSort] = useState(null)
  const [selection, setSelection] = useState(null)
  const { snapshot, connected, rejected } = useSnapshot(token)

  useEffect(() => {
    if (!snapshot) return
    if (sort === null) setSort(snapshot.listing.sort)
    if (selection === null) setSelection(emptySelection(snapshot.listing.hideParked))
  }, [snapshot, sort, selection])

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

  if (!snapshot || sort === null || selection === null) {
    return html`<div class="prompt"><p>Connecting…</p></div>`
  }

  const counts = sectionCounts(snapshot, query, selection)

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
                <span class="count">${flatten(snapshot).length} items</span>
                <!-- Installed to the home screen there is no browser chrome, so no way to
                     reload and pick up a new client. This is it. -->
                <button
                  class="reload"
                  aria-label="Reload the app"
                  onClick=${() => location.reload()}
                >⟳</button>
              </header>
              <${FilterBar}
                query=${query}
                onQuery=${setQuery}
                sort=${sort}
                sorts=${snapshot.listing.sorts}
                onSort=${setSort}
              />
              <${Pills}
                listing=${snapshot.listing}
                counts=${pillCounts(snapshot)}
                selection=${selection}
                onSelection=${setSelection}
              />
              <${Tabs} counts=${counts} tab=${tab} onSelect=${setTab} />
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
              selection=${selection}
              sort=${sort}
              counts=${counts}
              onOpen=${setOpenID}
            />
          `}
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
