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

See the authoritative table in [`PROTOCOL.md`](../PROTOCOL.md#http-api). Herdr commands are spawned with argv arrays; request values are never interpolated into a shell command.

## WebSocket

Connect with `GET /ws`. Actions remain HTTP-only.

| Direction | Message | Behavior |
| --- | --- | --- |
| server → client | `state` | Full snapshot on connect and every detected state diff |
| server → client | `output` | Changed plain-text output for the watched pane |
| server → client | `error` | Invalid message or watch/read failure |
| client → server | `watch` | Watch one pane, replacing the previous watch; output is pushed immediately |
| client → server | `unwatch` | Stop output polling |

The server polls watched output about every two seconds and sends WebSocket protocol pings every 30 seconds. Exact fields are frozen in [`PROTOCOL.md`](../PROTOCOL.md#websocket--get-ws).

## Test

```sh
bun test
```

Unit tests use captured CLI JSON in `test/fixtures/` and do not call Herdr or the network.
