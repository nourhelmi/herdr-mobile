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
      "label": "ai-tutor",
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
              "title": "nour@mac:~/Dev/x",      // terminal_title_stripped
              "cwd": "/Users/nour/Dev/x",
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
      "displayName": "π   claude-x   ai-tutor  $0.00",  // display_agent, may be null
      "paneId": "w1:pDF",
      "workspaceId": "w1",
      "tabId": "w1:tN",
      "state": "idle",                          // idle|working|blocked|done|unknown
      "cwd": "/Users/nour/Dev/x",
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
| POST | `/agent/:target/prompt` | body `{"text":"..."}` | `{"ok":true}` |
| POST | `/agent/:target/keys` | body `{"keys":["esc"]}` | `{"ok":true}` |

- `:id` / `:target` are URL-path-encoded (pane ids contain `:` — encode as `%3A`;
  the sidecar decodes). `:target` may be an agent name or a pane id.
- Errors: non-2xx with `{"ok":false,"error":"message"}`. Herdr CLI failures
  map to 502; bad input to 400; unknown pane/agent to 404 when detectable.
- Key names for `/keys` are passed through to `herdr agent send-keys`
  (e.g. `esc`, `ctrl+c`, `enter`).

## WebSocket — `GET /ws`

JSON text frames, every message has `type`.

### Server → client

| type | payload | when |
| --- | --- | --- |
| `state` | `{type:"state", state:<Snapshot>}` | on connect + on every detected diff |
| `output` | `{type:"output", paneId, text, format:"text"}` | watched pane output changed (~2s poll) |
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
- Actions (prompt/keys) always go over HTTP, never WS.

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
- `/pane/:id/input` wraps `herdr pane send-text`. Same text limits and
  flag-like rejection as `/agent/:target/prompt` (16,000 chars).
- Create wraps `herdr workspace create` and `herdr tab create --workspace`.
  No `--focus`. Refresh `/state` after success.

### WebSocket

`watch` accepts optional `format`: `"text"` (v1 default) or `"ansi"`.
Output frames echo that format. Terminal-mode clients should watch `ansi`
and render SGR locally; Prompt mode strips + trims Pi TUI chrome on device.
