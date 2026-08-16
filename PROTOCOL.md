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
