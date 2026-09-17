import {
  html,
  render,
  useState,
  useEffect,
  useCallback,
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

function App() {
  const [token, setToken] = useState(loadToken)
  const [openID, setOpenID] = useState(null)
  const { snapshot, connected, rejected } = useSnapshot(token)

  const pair = useCallback((value) => {
    saveToken(value)
    setToken(value)
  }, [])

  const forget = useCallback(() => {
    try {
      localStorage.removeItem(TOKEN_KEY)
    } catch {
      // Nothing to clear.
    }
    setToken(null)
  }, [])

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
      <header class="bar">
        <span class="brand">PR Pilot</span>
        <span class="count">${itemCount(snapshot)} items</span>
      </header>
      <${List} snapshot=${snapshot} onOpen=${setOpenID} />
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
