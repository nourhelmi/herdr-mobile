# Herdr Mobile sidecar

A Bun/TypeScript daemon that turns the local `herdr` CLI state into the frozen HTTP and WebSocket protocol in [`../PROTOCOL.md`](../PROTOCOL.md).

## Run

Requirements: Bun, a running Herdr server, the `herdr` CLI in `PATH`, and optionally the Tailscale CLI.

```sh
cd sidecar
bun install
bun run start
```

The daemon listens on port `8787` by default. Set `PORT` to choose another port. It binds separate listeners to `127.0.0.1` and the IPv4 returned by `tailscale ip -4`; it never binds `0.0.0.0`. Absence of Tailscale leaves the loopback listener active.

On startup it prints the generated ntfy topic. Runtime state is stored under `sidecar/state/` (gitignored):

- `config.json` — the stable random `ntfyTopic`
- `notification-state.json` — pane-keyed last states and debounce timestamps

## HTTP

See the frozen v1/v1.1 tables in [`PROTOCOL.md`](../PROTOCOL.md#http-api), the [v2 addendum](../PROTOCOL.md#v2-addendum), and the [pane-keys addendum](../PROTOCOL.md#pane-keys-addendum). Herdr commands are spawned with argv arrays; request values are never interpolated into a shell command.

`POST /pane/:id/keys` wraps `herdr pane send-keys <paneId> ...keys` with the
same validation as `POST /agent/:target/keys`, so an ordinary (non-agent)
pane can receive Enter, Esc, Ctrl-C, arrow keys, and Backspace — not just
printable text via `/pane/:id/input`.

`POST /agent/:target/acknowledge` is bodyless and wraps only `herdr agent focus <target>`. A 2xx response means that argv call and a sidecar agent poll both completed; clients then fetch `/state`. A successful mutation whose poll fails returns 502 and must be refreshed before retrying. Workspace and tab creation use the same freshness rule with a structure poll.

Input limits are enforced before invoking Herdr: JSON request bodies are capped at 64 KiB, input text at 16,000 characters, key arrays at 32 entries with 128 characters per key, and pane output at 2,000 lines for both HTTP and WebSocket requests. Limit violations return HTTP 400 or a WebSocket `error` frame.

`GET /pane/:id/history` reads up to 2,000 `recent-unwrapped` ANSI rows on demand and reports whether the oldest available output was reached. It is intentionally separate from the 100ms visible-screen watch so browsing a long transcript does not make every live poll return the entire history. Fresh panes fall back to their visible screen.

Herdr 0.8.0 does not honor `--` as an option delimiter for `pane read`, `pane send-text`, or `agent send-keys`. The sidecar therefore rejects pane IDs, agent targets, input text, and key names beginning with `-` rather than allowing them to be parsed as CLI flags.

## WebSocket

Connect with `GET /ws`. Actions remain HTTP-only.

| Direction | Message | Behavior |
| --- | --- | --- |
| server → client | `state` | Full snapshot on connect and every detected state diff |
| server → client | `output` | Changed plain-text output for the watched pane |
| server → client | `error` | Invalid message or watch/read failure |
| client → server | `watch` | Watch one pane, replacing the previous watch; output is pushed immediately |
| client → server | `unwatch` | Stop output polling |

The server polls each watched pane's visible terminal screen about every 100ms. Using `visible` (rather than `recent-unwrapped`) keeps fresh shells and Pi immediately after `/new` renderable before they have scrollback. A successful `POST /pane/:id/input` or `POST /agent/:target/keys` immediately queues one serialized pane read for matching watchers (in-flight pokes coalesce to one follow-up). The server sends WebSocket protocol pings every 30 seconds. Exact fields are frozen in [`PROTOCOL.md`](../PROTOCOL.md#websocket--get-ws). v1.1 adds optional `watch.format` (`text` default, `ansi` for SGR clients), parsed `display` on agents, and HTTP create/input routes — see the v1.1 addendum.

## Test

```sh
bun test
```

Unit tests use captured CLI JSON in `test/fixtures/` and do not call Herdr or the network.
