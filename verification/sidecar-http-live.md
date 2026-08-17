# Live HTTP verification (bounded)

> **HISTORICAL** — captured 2026-08-17 06:08Z when `POST /agent/:target/prompt` still existed.
> Current contract: `verification/sidecar-http-current.md`. The prompt sections below are not current behavior.

Target: <http://127.0.0.1:8787> (explicit loopback; no wildcard bind)

## GET /health

HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Mon, 17 Aug 2026 06:08:41 GMT
Content-Length: 42

## GET /state (safe test workspace projection)

{"generatedAt":"2026-08-17T06:08:08.297Z","workspaceCount":5,"agentCount":5,"safeWorkspace":{"id":"w5","label":"HM-CHECK-202608170607023376","number":5,"focused":false,"tabs":[{"id":"w5:t1","label":"1","number":1,"focused":false,"agentStatus":"idle","panes":[{"id":"w5:p1","label":null,"title":"π - herdr-mobile-check-202608170607023376","cwd":"/private/tmp/herdr-mobile-check-202608170607023376","isAgent":true,"agent":{"name":"pi","displayName":"π   claude-fable-5   herdr-mobile-check-202608170607023376   $0.00","paneId":"w5:p1","workspaceId":"w5","tabId":"w5:t1","state":"idle","cwd":"/private/tmp/herdr-mobile-check-202608170607023376","paneLabel":null}}]}]},"safeAgent":{"name":"pi","paneId":"w5:p1","workspaceId":"w5","tabId":"w5:t1","state":"idle","cwd":"/private/tmp/herdr-mobile-check-202608170607023376","paneLabel":null}}

## GET /pane/w5%3Ap1/output?lines=40&format=text

HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Mon, 17 Aug 2026 06:08:41 GMT
Content-Length: 44

{"paneId":"w5:p1","format":"text","text":""}

## GET /pane/w5%3Ap1/output?lines=40&format=ansi

HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Mon, 17 Aug 2026 06:08:41 GMT
Content-Length: 44

{"paneId":"w5:p1","format":"ansi","text":""}

## HISTORICAL — POST /agent/w5%3Ap1/prompt (removed; now generic 404)

HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Mon, 17 Aug 2026 06:08:41 GMT
Content-Length: 11

{"ok":true}

## POST /agent/w5%3Ap1/keys

HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Mon, 17 Aug 2026 06:08:41 GMT
Content-Length: 11

{"ok":true}

## HISTORICAL — GET /pane/w5%3Ap1/output after the removed prompt route

{"paneId":"w5:p1","format":"text","text":"\n\n╰─ ○ 5.2%/1M  󰔛 2m  󰧑 high ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n 🔀 Orchestrator · disabled (no taskplane config in workspace) · LSP Inactive · 🔌 MCP: 4 servers enabled"}

## Listener binding

Startup logged explicit listeners `127.0.0.1:8787` and `100.64.0.2:8787`; no `0.0.0.0` listener was observed.
