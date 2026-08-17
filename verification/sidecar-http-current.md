# Current HTTP contract (live-only)

Product SHA: `aed19175ac20bc373b66a97405756a7c05a759a6`.
Source of truth: `PROTOCOL.md`. No new live Herdr session was opened for this note.

## Live writes

| Method | Path | Body | Current result |
| --- | --- | --- | --- |
| POST | `/pane/:id/input` | `{"text":"..."}` | `{"ok":true}` — `herdr pane send-text`; pokes matching watchers |
| POST | `/agent/:target/keys` | `{"keys":["esc"]}` | `{"ok":true}` — `herdr agent send-keys`; pokes matching watchers |

iOS Agent Detail is live-only (composer + quick keys). There is no PROMPT/TERM selector and no prompt-mode HTTP path.

## Removed prompt route

`POST /agent/:target/prompt` has no handler. It falls through to the unknown-route response:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json;charset=utf-8

{"ok":false,"error":"Not found"}
```

It does **not** spawn `herdr agent prompt` and does **not** return `{"ok":true}`.

## Deterministic evidence

`cd sidecar && bun test` at `aed1917`: **41 pass, 0 fail, 242 expect()**, 5 files.

Assertions that replace the historical prompt transcripts:

- `maps bad input, missing targets, and CLI failures to 400, 404, and 502` — `POST /agent/pi/prompt` → 404
- `creates a workspace and tab, and forwards raw pane text` — `POST /pane/:id/input`
- `pokes an immediate read after input and keys without waiting for the poll interval`
- `rejects oversized bodies, input text, …` and `rejects flag-like pane IDs, targets, input text, …` (names no longer say “prompt text”)

Historical captures that still show the old route or PROMPT/TERM UI are labeled in `sidecar-http-live.md`, `sidecar-http.md`, `sidecar-tests-v11.txt`, and `screenshots/README.md`.
