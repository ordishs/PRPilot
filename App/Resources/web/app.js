import {
  html,
  render,
  useState,
  useEffect,
  useCallback,
  useMemo,
  useRef,
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
import {
  detailOf,
  detailTabs,
  activeTab,
  addableAgents,
  needsSession,
  agentOptions,
  itemActions,
} from '/detail.mjs'

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

async function fetchThread(token, id) {
  const response = await fetch(`/api/github?id=${encodeURIComponent(id)}`, {
    headers: { authorization: `Bearer ${token}` },
  })
  if (!response.ok) throw new Error(`GitHub failed (${response.status})`)
  return response.json()
}

function stamp(iso) {
  if (!iso) return ''
  const at = new Date(iso)
  return Number.isNaN(at.getTime())
    ? ''
    : at.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })
}

const VERDICT_TONES = { APPROVED: 'green', CHANGES_REQUESTED: 'red' }

/// The issue or PR text, fetched by the Mac. github.com refuses to be framed and the
/// phone holds no GitHub session, so the page cannot be embedded the way the Mac does.
/// Bodies are shown as plain text: the markup stays visible rather than being guessed at.
function GitHubThread({ item, token, onError }) {
  const [thread, setThread] = useState(null)

  const load = useCallback(async () => {
    try {
      setThread(await fetchThread(token, item.id))
    } catch (error) {
      onError(String(error.message || error))
    }
  }, [token, item.id, onError])

  useEffect(() => {
    load()
    const timer = setInterval(load, 30000)
    return () => clearInterval(timer)
  }, [load])

  if (!thread) return html`<p class="conv-note">Loading the GitHub page…</p>`
  if (!thread.available) return html`<p class="conv-note">${thread.note || 'No GitHub page.'}</p>`

  return html`
    <div class="thread">
      <div class="thread-head">
        <span class="badge grey">${thread.state.toLowerCase()}</span>
        ${thread.labels.map((name) => html`<span key=${name} class="badge blue">${name}</span>`)}
        <span class="thread-by">${thread.author} · ${stamp(thread.createdAt)}</span>
      </div>
      <div class="turn-text thread-body">
        ${thread.body.trim() === '' ? 'No description provided.' : thread.body}
      </div>
      ${thread.entries.map(
        (entry, index) => html`
          <div key=${`${entry.at}-${index}`} class="turn">
            <div class="turn-head">
              ${entry.author} · ${stamp(entry.at)}
              ${entry.verdict &&
                html` <span class=${`badge ${VERDICT_TONES[entry.verdict] || 'grey'}`}>
                  ${entry.verdict.replace('_', ' ').toLowerCase()}
                </span>`}
            </div>
            ${entry.body.trim() !== '' && html`<div class="turn-text">${entry.body}</div>`}
          </div>
        `
      )}
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

const RESOURCE_GLYPHS = { worktree: '▤', session: '›_', web: '◎' }

const STATUS_TONES = {
  starting: 'orange',
  working: 'orange',
  'awaiting input': 'blue',
  idle: 'green',
  finished: 'green',
  limited: 'red',
  failed: 'red',
}

/// The Mac row's trailing status dot: the agent's state at a glance.
function StatusDot({ agent }) {
  if (!agent) return null
  return html`<span
    class=${`status-dot ${STATUS_TONES[agent.status] || 'grey'}`}
    title=${`${agent.kind} · ${agent.status}`}
  ></span>`
}

/// One sidebar row, laid out as the Mac draws it: number and title, badges, label,
/// owner/repo and author, then resource icons with the age of the last activity.
function Row({ item, selected, resourceFilters, onOpen, onMenu }) {
  const timer = useRef(null)
  const fired = useRef(false)
  const dim = item.isDisabled

  const cancel = () => {
    clearTimeout(timer.current)
    timer.current = null
  }
  const press = () => {
    fired.current = false
    cancel()
    timer.current = setTimeout(() => {
      fired.current = true
      onMenu(item)
      setTimeout(() => {
        fired.current = false
      }, 800)
    }, 500)
  }
  const click = () => {
    if (fired.current) {
      fired.current = false
      return
    }
    onOpen(item.id)
  }
  const where = item.repo ? `${item.owner}/${item.repo}` : 'task'
  const meta = [where, item.author].filter(Boolean).join(' · ')

  return html`
    <button
      class=${`row${dim ? ' dim' : ''}${selected ? ' selected' : ''}`}
      onClick=${click}
      onTouchStart=${press}
      onTouchEnd=${cancel}
      onTouchMove=${cancel}
      onTouchCancel=${cancel}
      onContextMenu=${(event) => {
        event.preventDefault()
        onMenu(item)
      }}
    >
      <div class="row-main">
        <div class="row-title">${item.number != null ? `#${item.number} · ` : ''}${item.title}</div>
        ${item.attentionReason &&
          html`<div class="row-reason">${item.attentionReason}</div>`}
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
        ${item.label && html`<div class="row-label">🔖 ${item.label}</div>`}
        <div class="row-meta">${meta}</div>
        <div class="row-foot">
          ${resourceFilters.map(
            (option) => html`
              <span
                key=${option.key}
                class=${item.resources.includes(option.key) ? 'res on' : 'res'}
                title=${option.help}
              >${RESOURCE_GLYPHS[option.key] || '•'}</span>
            `
          )}
          <span class="row-age">${ago(item.lastActivityAt)}</span>
        </div>
      </div>
      <${StatusDot} agent=${item.agent} />
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

const COLLAPSED_KEY = 'prpilot.collapsed'

function loadCollapsed() {
  try {
    return new Set(JSON.parse(localStorage.getItem(COLLAPSED_KEY) || '[]'))
  } catch {
    return new Set()
  }
}

function saveCollapsed(set) {
  try {
    localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...set]))
  } catch {
    // Not fatal — the sections stay as the viewer left them for this tab.
  }
}

/// The Mac sidebar: all three sections in one scrolling list, each with a collapsible
/// heading and a count. Search and pills narrow every section, as on the Mac.
function Sidebar({ snapshot, query, selection, sort, counts, openID, onOpen, onMenu }) {
  const [collapsed, setCollapsed] = useState(loadCollapsed)
  const narrowed = query.trim() !== '' || !selectionIsEmpty(selection)
  const total = SECTION_ORDER.reduce((sum, kind) => sum + counts[kind], 0)

  const toggleSection = (kind) => {
    const next = toggled(collapsed, kind)
    saveCollapsed(next)
    setCollapsed(next)
  }

  return html`
    <div class="list">
      ${snapshot.warnings.length > 0 &&
        html`<div class="warnings">${snapshot.warnings.join(' · ')}</div>`}
      ${narrowed && total === 0 && html`<p class="empty">Nothing here matches.</p>`}
      ${SECTION_ORDER.map((kind) => {
        const items = visibleItems(snapshot, kind, query, selection, sort)
        const open = !collapsed.has(kind)
        return html`
          <section key=${kind} class="section">
            <button
              class="section-head"
              aria-expanded=${open}
              onClick=${() => toggleSection(kind)}
            >
              <span class="chevron">${open ? '▾' : '▸'}</span>
              <span class="section-title">${SECTION_TITLES[kind]}</span>
              <span class="section-count">${counts[kind]}</span>
            </button>
            ${open &&
              (items.length === 0
                ? html`<p class="section-empty">Nothing here yet</p>`
                : items.map(
                    (item) => html`
                      <${Row}
                        key=${item.id}
                        item=${item}
                        selected=${item.id === openID}
                        resourceFilters=${snapshot.listing.resourceFilters}
                        onOpen=${onOpen}
                        onMenu=${onMenu}
                      />
                    `
                  ))}
          </section>
        `
      })}
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

async function runEntry(entry, { token, onError, onNotice }) {
  if (entry.choices) return { choices: entry.choices }

  if (entry.copy) {
    try {
      await navigator.clipboard.writeText(entry.copy)
      onNotice('Copied.')
    } catch {
      onError('Copy failed. The browser blocked the clipboard.')
    }
    return {}
  }

  if (entry.confirm && !window.confirm(entry.confirm)) return {}

  let command = entry.command
  if (entry.prompt) {
    const text = window.prompt('Label', entry.prompt.label)
    if (text === null) return {}
    command = { ...entry.prompt, label: text.trim() === '' ? null : text.trim() }
  }

  try {
    const result = await sendCommand(token, command)
    if (result.status === 'rejected') {
      onError(result.message || 'The Mac refused that command.')
    } else if (result.message) {
      onNotice(result.message)
    }
  } catch (error) {
    onError(String(error.message || error))
  }
  return {}
}

function ActionMenu({ title, entries, onPick, onClose }) {
  const openedAt = useRef(Date.now())
  const closeFromBackdrop = () => {
    if (Date.now() - openedAt.current > 400) onClose()
  }

  return html`
    <div class="menu-backdrop" onClick=${closeFromBackdrop}>
      <div class="menu" onClick=${(event) => event.stopPropagation()}>
        <div class="menu-title">${title}</div>
        ${entries.map(
          (entry) => html`
            <button
              key=${entry.key || entry.label}
              class=${entry.danger ? 'danger' : ''}
              onClick=${() => onPick(entry)}
            >
              ${entry.checked ? '✓ ' : ''}${entry.label}
            </button>
          `
        )}
        <button class="menu-cancel" onClick=${onClose}>Cancel</button>
      </div>
    </div>
  `
}

function MenuHost({ menu, onMenu, token, onError, onNotice }) {
  if (!menu) return null

  const pick = async (entry) => {
    const outcome = await runEntry(entry, { token, onError, onNotice })
    if (outcome.choices) {
      onMenu({ title: entry.label, entries: outcome.choices })
    } else {
      onMenu(null)
      if (entry.after) entry.after()
    }
  }

  return html`
    <${ActionMenu}
      title=${menu.title}
      entries=${menu.entries}
      onPick=${pick}
      onClose=${() => onMenu(null)}
    />
  `
}

function RebaseBanner({ rebase }) {
  if (!rebase) return null

  if (rebase.state === 'conflicted') {
    const count = rebase.files.length
    return html`
      <div class="banner warn">
        Rebase paused — ${count} conflict${count === 1 ? '' : 's'}. Resolve it on the Mac.
      </div>
    `
  }

  return html`
    <div class="banner error">Rebase failed: ${rebase.message}. Dismiss it on the Mac.</div>
  `
}

function Detail({ item, snapshot, token, onError, onNotice }) {
  const [busy, setBusy] = useState(null)
  const [chosen, setChosen] = useState(null)
  const [menu, setMenu] = useState(null)
  const started = useRef(null)

  const detail = detailOf(item)
  const pane = activeTab(item, chosen)
  const agentName = (key) => snapshot.listing.agents.find((agent) => agent.key === key)?.label
  const agentLabel = agentName(detail.agentKey) || item.agent?.kind || 'Agent'
  const onAgentTab = pane !== 'github'
  const switching = onAgentTab && pane !== detail.agentKey

  const run = async (command, key) => {
    setBusy(key)
    try {
      const result = await sendCommand(token, command)
      if (result.status === 'rejected') {
        onError(result.message || 'The Mac refused that command.')
      } else if (result.message) {
        onNotice(result.message)
      }
    } catch (error) {
      onError(String(error.message || error))
    } finally {
      setBusy(null)
    }
  }

  // Only one agent runs an item at a time, so another agent's tab switches the live
  // session to it. Each agent keeps its own conversation to come back to.
  const chooseTab = (key) => {
    setChosen(key)
    if (key !== 'github' && key !== detail.agentKey) {
      run({ type: 'setAgent', id: item.id, agent: key }, 'switch')
    }
    sendCommand(token, {
      type: 'setPane',
      id: item.id,
      pane: key === 'github' ? 'github' : 'claude',
    }).catch((error) => onError(String(error.message || error)))
  }

  const addMenu = () => {
    const confirm = item.agent?.status === 'working'
      ? 'The agent is working. Switching ends its live session.'
      : null
    setMenu({
      title: 'Add review',
      entries: addableAgents(snapshot, item).map((option) => ({
        ...option,
        confirm,
        after: () => setChosen(option.key),
      })),
    })
  }

  useEffect(() => {
    if (!onAgentTab || switching || !needsSession(item)) return
    if (started.current === item.id) return
    started.current = item.id
    sendCommand(token, { type: 'startSession', id: item.id, forceFresh: false }).catch((error) =>
      onError(String(error.message || error))
    )
  }, [pane, item.id, detail.paneState, item.isDisabled, detail.agentKey])

  const primaryCommand = item.primaryCommand || { type: 'startSession', id: item.id, forceFresh: true }
  const primaryLabel = item.primaryCommand
    ? PRIMARY_LABELS[item.primaryCommand.type] || 'Run'
    : 'Fresh session'

  const stats = [elapsed(item.agent?.elapsedSeconds), item.agent?.usedPercent != null ? `${item.agent.usedPercent}%` : null]
    .filter(Boolean)
    .join(' · ')

  const tabLabel = (key) => (key === 'github' ? 'GitHub' : `${agentName(key) || key} Review`)
  const canAdd = addableAgents(snapshot, item).length > 0

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

      <${RebaseBanner} rebase=${detail.rebase} />

      <div class="segments" role="tablist">
        ${detailTabs(item).map(
          (key) => html`
            <button
              key=${key}
              role="tab"
              aria-selected=${pane === key}
              class=${pane === key ? 'on' : ''}
              onClick=${() => chooseTab(key)}
            >
              ${tabLabel(key)}
            </button>
          `
        )}
        ${canAdd &&
          html`<button class="add-tab" aria-label="Add review" onClick=${addMenu}>+</button>`}
      </div>

      ${onAgentTab && !switching && detail.runLabel && html`<div class="run-label">${detail.runLabel}</div>`}

      ${pane === 'github' &&
        html`
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

          <div class="label">Discussion</div>
          <${GitHubThread} item=${item} token=${token} onError=${onError} />
        `}

      ${onAgentTab &&
        html`
          <div class="agent-head">
            <span class="agent-kind">${agentLabel}${item.agent ? ` · ${item.agent.status}` : ''}</span>
            <button
              class="agent-menu"
              onClick=${() => setMenu({ title: 'Agent', entries: agentOptions(snapshot, item) })}
            >
              Agent ▾
            </button>
          </div>

          ${switching && html`<p class="conv-note">Switching to ${agentName(pane) || pane}…</p>`}
          ${!switching && detail.paneState === 'live' &&
            html`<${Conversation} item=${item} token=${token} onError=${onError} />`}
          ${!switching && detail.paneState === 'idle' &&
            html`
              <p class="conv-note">No session yet.</p>
              <button
                class="start"
                disabled=${busy !== null}
                onClick=${() => run({ type: 'startSession', id: item.id, forceFresh: false }, 'start')}
              >
                ${busy === 'start' ? 'Working…' : 'Start'}
              </button>
            `}
          ${!switching && detail.paneState === 'preparing' && html`<p class="conv-note">Preparing the worktree…</p>`}
          ${!switching && (detail.paneState === 'failed' || detail.paneState === 'unavailable') &&
            html`<div class="banner error">${detail.paneMessage || 'The agent could not start.'}</div>`}
        `}

      <div class="sheet-spacer"></div>

      <div class="sheet">
        <button
          class="primary"
          disabled=${busy !== null}
          onClick=${() => run(primaryCommand, 'primary')}
        >
          ${busy === 'primary' ? 'Working…' : primaryLabel}
        </button>
        <div class="sheet-row">
          <button
            disabled=${busy !== null}
            onClick=${() => run({ type: 'startSession', id: item.id, forceFresh: true }, 'fresh')}
          >
            ${busy === 'fresh' ? '…' : item.agent ? 'Restart fresh' : 'Fresh session'}
          </button>
          <button
            class="more"
            aria-label="More actions"
            onClick=${() => setMenu({ title: 'Actions', entries: itemActions(snapshot, item) })}
          >•••</button>
        </div>
      </div>

      <${MenuHost}
        menu=${menu}
        onMenu=${setMenu}
        token=${token}
        onError=${onError}
        onNotice=${onNotice}
      />
    </div>
  `
}

function App() {
  const [token, setToken] = useState(loadToken)
  const [openID, setOpenID] = useState(null)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  const [menu, setMenu] = useState(null)
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
    <div class=${open ? 'app has-open' : 'app'}>
      <div class="chrome">
        ${!connected && html`<div class="offline">Reconnecting…</div>`}
        ${error && html`<div class="error" onClick=${() => setError(null)}>${error}</div>`}
        ${notice && html`<div class="notice" onClick=${() => setNotice(null)}>${notice}</div>`}
      </div>
      <div class="layout">
        <aside class="sidebar">
          <div class="side-chrome">
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
          </div>
          <${Sidebar}
            snapshot=${snapshot}
            query=${query}
            selection=${selection}
            sort=${sort}
            counts=${counts}
            openID=${openID}
            onOpen=${setOpenID}
            onMenu=${(item) => setMenu({ title: item.title, entries: itemActions(snapshot, item) })}
          />
        </aside>
        <main class="main">
          ${open
            ? html`
                <div class="detail-bar">
                  <button class="back" onClick=${() => setOpenID(null)}>‹ Back</button>
                  <span class="detail-bar-title">${open.repo ? `${open.repo} #${open.number}` : 'task'}</span>
                </div>
                <${Detail}
                  key=${open.id}
                  item=${open}
                  snapshot=${snapshot}
                  token=${token}
                  onError=${setError}
                  onNotice=${setNotice}
                />
              `
            : html`<p class="main-empty">Select an item.</p>`}
        </main>
      </div>
      <${MenuHost}
        menu=${menu}
        onMenu=${setMenu}
        token=${token}
        onError=${setError}
        onNotice=${setNotice}
      />
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
