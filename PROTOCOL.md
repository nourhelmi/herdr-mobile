# Herdr Mobile — Sidecar ↔ iOS Protocol (v1)

Single source of truth for both the sidecar and the iOS app. Sidecar default
port: **8787**. All bodies are JSON. No auth (Tailscale is the boundary).

## Snapshot shape

The combined state tree the sidecar builds from the Herdr CLI:

```jsonc
{
  "generatedAt": "2026-08-16T12:00:00.000Z",   // ISO-8601
  "workspaces": [
    {
      "id": "w1",
      "label": "sample-api",
      "number": 1,
      "focused": false,
      "agentStatus": "idle",                    // rollup from herdr
      "tabs": [
        {
          "id": "w1:t4",
          "label": "server",
          "number": 4,
          "focused": false,
          "agentStatus": "unknown",
          "panes": [
            {
              "id": "w1:p7",
              "label": null,                    // pane label or null
              "title": "user@host:~/Dev/x",      // terminal_title_stripped
              "cwd": "/Users/dev/x",
              "isAgent": false,
              "agent": null
            }
          ]
        }
      ]
    }
  ],
  "agents": [
    {
      "name": "pi",                            // agent kind label from herdr
      "displayName": "π   claude-x   sample-api  $0.00",  // display_agent, may be null
      "paneId": "w1:pDF",
      "workspaceId": "w1",
      "tabId": "w1:tN",
      "state": "idle",                          // idle|working|blocked|done|unknown
      "cwd": "/Users/dev/x",
      "paneLabel": "advisor-okay-so..."         // pane label or null
    }
  ]
}
```

Notes:

- `agents[]` is flat and is the primary list for the Home screen.
- A pane with `isAgent: true` embeds the same agent object under `agent`.
- Agent `state` is passed through verbatim from `herdr agent list`
  (`agent_status`); clients must tolerate unknown values (render as `unknown`).
- Agent identity key for diffing/notifications: `paneId` (names can collide).

## HTTP API

| Method | Path | Query/Body | Response |
| --- | --- | --- | --- |
| GET | `/health` | — | `{"ok":true,"version":"1.x","herdr":true}` (`herdr:false` if last poll failed) |
| GET | `/state` | — | Snapshot (above) |
| GET | `/pane/:id/output` | `lines` (default 200), `format` = `text`\|`ansi` (default `text`) | `{"paneId":"w1:p7","format":"text","text":"..."}` |
| POST | `/agent/:target/keys` | body `{"keys":["esc"]}` | `{"ok":true}` |
| POST | `/pane/:id/keys` | body `{"keys":["esc"]}` | `{"ok":true}` |

- `:id` / `:target` are URL-path-encoded (pane ids contain `:` — encode as `%3A`;
  the sidecar decodes). `:target` may be an agent name or a pane id.
- Errors: non-2xx with `{"ok":false,"error":"message"}`. Herdr CLI failures
  map to 502; bad input to 400; unknown pane/agent to 404 when detectable.
- Key names for `/agent/:target/keys` are passed through to
  `herdr agent send-keys` (e.g. `esc`, `ctrl+c`, `enter`). `/pane/:id/keys`
  takes the same body shape and validation and wraps `herdr pane send-keys
  <paneId> ...keys` instead — use it for a bare pane that has no agent.

## WebSocket — `GET /ws`

JSON text frames, every message has `type`.

### Server → client

| type | payload | when |
| --- | --- | --- |
| `state` | `{type:"state", state:<Snapshot>}` | on connect + on every detected diff |
| `output` | `{type:"output", paneId, text, format:"text"}` | watched pane output changed (~100ms poll; input/keys poke an immediate read) |
| `error` | `{type:"error", message}` | bad client message or watch failure |

### Client → server

| type | payload | effect |
| --- | --- | --- |
| `watch` | `{type:"watch", paneId, lines?}` (lines default 200) | start polling that pane; replaces any previous watch for this connection; immediately pushes current output |
| `unwatch` | `{type:"unwatch"}` | stop pane polling |

- One watched pane per connection (the app watches one pane at a time).
- Server sends WS protocol-level pings every 30s. Client reconnects with
  exponential backoff (1s, 2s, 4s… cap 30s) and re-sends `watch` after
  reconnect.
- Actions (input/keys) always go over HTTP, never WS.
- After a successful `POST /pane/:id/input` (`pane send-text`),
  `POST /agent/:target/keys` (`agent send-keys`), or `POST /pane/:id/keys`
  (`pane send-keys`), the sidecar immediately queues one serialized pane read
  on every WebSocket watcher whose watched pane matches. Agent keys resolve
  `target` → pane id from the current snapshot (pane id first, then agent
  name); pane keys always target the pane id directly. A poke while a read is
  in flight coalesces to one follow-up; it does not stack unbounded reads.
  Unwatch bumps generation, so a poke after unwatch is a no-op.

## v1.1 addendum

Additive. The v1 tables above stay the contract. v1 clients ignore unknown
fields and unused routes.

### Snapshot

Each `agents[]` item (and embedded `pane.agent`) gains:

```jsonc
"display": {
  "text": "π · gpt-5.6-luna · herdr-mobile · main · $0.56",
  "model": "gpt-5.6-luna",
  "repo": "herdr-mobile",
  "branch": "main",          // null when Herdr omitted it
  "cost": "$0.56"
}
```

Parsed from Herdr `display_agent`. `displayName` remains the raw string
(Powerline/Nerd PUA separators). `display.text` is that string with Private
Use scalars removed and fields joined by ` · `. Home and the agent status
chip should prefer `display`.

### HTTP

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| POST | `/workspace` | `{"label"?:"..."}` | `{"ok":true}` |
| POST | `/workspace/:id/tab` | `{"label"?:"..."}` | `{"ok":true}` |
| POST | `/pane/:id/input` | `{"text":"..."}` | `{"ok":true}` |

- Labels are optional user text. Max 128 characters. Rejected if they start
  with `-` (Herdr 0.8 treats those as flags). Empty/`{}` omits `--label`.
- `/pane/:id/input` wraps `herdr pane send-text`. Text is capped at 16,000
  characters and rejected if flag-like (starts with `-`).
- Create wraps `herdr workspace create` and `herdr tab create --workspace`.
  No `--focus`. Refresh `/state` after success.

### WebSocket

`watch` accepts optional `format`: `"text"` (v1 default) or `"ansi"`.
Output frames echo that format. Clients that want terminal styling should watch
`ansi` and render SGR locally. The iOS client requests `ansi` and uses the same
ANSI-colored terminal renderer. Agent detail and bare-pane terminal mode both
forward live pane input and keys only; there is no prompt-mode HTTP path.

## v2 addendum

Additive. The v1 and v1.1 tables above stay the contract.

### HTTP

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| POST | `/agent/:target/acknowledge` | none | `{"ok":true}` |

- Bodyless. Do not send `Content-Type` or `{}`.
- iOS always supplies the URL-encoded `AgentSnapshot.paneId`. The sidecar
  decodes `:target` and rejects flag-like values (400) before spawning.
- The route wraps only argv `herdr agent focus <target>`. No shell
  interpolation, aliases, or extra payload fields.
- Detectable missing targets map to 404. CLI failures map to 502 with a
  redacted `"Herdr command failed"` message.
- 2xx means the focus command and a sidecar **agent** poll both completed.
  Clients then fetch `/state` before showing success. `state` may remain
  `done` because focus marks the completion seen, not a state transition.
- If focus succeeds but the sidecar poll fails, the response is 502
  `{"ok":false,"error":"Agent was acknowledged, but state refresh failed; refresh before retrying"}`.
  Refresh before retrying. Do not treat this as an untouched cache.

Workspace and tab creation use the same freshness rule with a **structure**
poll and route-specific partial-success text (`Workspace was created` /
`Tab was created`). Keys and pane input keep periodic WS state and poke
matching watchers for an immediate serialized read.

## Close-controls addendum

Additive. The v1, v1.1, and v2 tables above stay the contract.

### HTTP

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| DELETE | `/pane/:id` | none | `{"ok":true}` |
| DELETE | `/tab/:id` | none | `{"ok":true}` |
| DELETE | `/workspace/:id` | none | `{"ok":true}` |

- Bodyless. Do not send `Content-Type` or `{}`.
- Exact argv only: `herdr pane close <paneId>`, `herdr tab close <tabId>`,
  `herdr workspace close <workspaceId>`. No shell interpolation, aliases, or
  extra payload fields.
- The sidecar decodes `:id` and rejects flag-like values (400) before spawning.
- Detectable missing targets map to 404. CLI failures map to 502 with a
  redacted `"Herdr command failed"` message. Do not treat a CLI failure as a
  blanket 500.
- 2xx means the close command and a sidecar **structure** poll both completed.
  Clients then fetch `/state` before showing success.
- If close succeeds but the sidecar poll fails, the response is 502
  `{"ok":false,"error":"<resource> was closed, but state refresh failed; refresh before retrying"}`
  (`Pane was closed` / `Tab was closed` / `Workspace was closed`). Refresh
  before retrying. Do not treat this as an untouched cache.

### Interrupt

No new route. Interrupt reuses `POST /agent/:target/keys` with
`{"keys":["ctrl+c"]}`, which wraps `herdr agent send-keys <target> ctrl+c`.
That is non-destructive: layout is preserved, and keys keep periodic WS state
(no post-mutation structure poll). A successful interrupt still pokes matching
watchers for an immediate serialized read.

### Live output

Watched pane output polls every **100ms**. A successful pane input or agent
keys action does not wait for that interval: it queues one serialized
`pane read` on each matching watcher (see WebSocket notes above).

## Pane-keys addendum

Additive. The v1, v1.1, v2, and close-controls tables above stay the contract.

### HTTP

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| POST | `/pane/:id/keys` | `{"keys":["esc"]}` | `{"ok":true}` |

- Same validation as `/agent/:target/keys`: at most 32 keys, 128 characters
  each, none flag-like. Wraps exact argv `herdr pane send-keys <paneId>
  ...keys`. No shell interpolation, aliases, or extra payload fields.
- Detectable missing panes map to 404. CLI failures map to 502 with a
  redacted `"Herdr command failed"` message.
- Non-destructive: no structure poll, matching `/agent/:target/keys`. A
  successful call still pokes matching watchers for an immediate serialized
  read.
- Ordinary (non-agent) panes are genuinely interactive: printable text goes
  through `/pane/:id/input`, and Enter, Esc, Ctrl-C, arrow keys, and
  Backspace go through `/pane/:id/keys`. Bare panes are not read-only.
