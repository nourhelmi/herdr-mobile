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

See the frozen v1/v1.1 tables in [`PROTOCOL.md`](../PROTOCOL.md#http-api) and the [v2 addendum](../PROTOCOL.md#v2-addendum). Herdr commands are spawned with argv arrays; request values are never interpolated into a shell command.

`POST /agent/:target/acknowledge` is bodyless and wraps only `herdr agent focus <target>`. A 2xx response means that argv call and a sidecar agent poll both completed; clients then fetch `/state`. A successful mutation whose poll fails returns 502 and must be refreshed before retrying. Workspace and tab creation use the same freshness rule with a structure poll.

Input limits are enforced before invoking Herdr: JSON request bodies are capped at 64 KiB, prompt text at 16,000 characters, key arrays at 32 entries with 128 characters per key, and pane output at 2,000 lines for both HTTP and WebSocket requests. Limit violations return HTTP 400 or a WebSocket `error` frame.

Herdr 0.8.0 does not honor `--` as an option delimiter for `pane read`, `agent prompt`, or `agent send-keys`. The sidecar therefore rejects pane IDs, agent targets, prompt text, and key names beginning with `-` rather than allowing them to be parsed as CLI flags.

## WebSocket

Connect with `GET /ws`. Actions remain HTTP-only.

| Direction | Message | Behavior |
| --- | --- | --- |
| server → client | `state` | Full snapshot on connect and every detected state diff |
| server → client | `output` | Changed plain-text output for the watched pane |
| server → client | `error` | Invalid message or watch/read failure |
| client → server | `watch` | Watch one pane, replacing the previous watch; output is pushed immediately |
| client → server | `unwatch` | Stop output polling |

The server polls watched output about every 250ms and sends WebSocket protocol pings every 30 seconds. Exact fields are frozen in [`PROTOCOL.md`](../PROTOCOL.md#websocket--get-ws). v1.1 adds optional `watch.format` (`text` default, `ansi` for SGR clients), parsed `display` on agents, and HTTP create/input routes — see the v1.1 addendum.

## Test

```sh
bun test
```

Unit tests use captured CLI JSON in `test/fixtures/` and do not call Herdr or the network.
